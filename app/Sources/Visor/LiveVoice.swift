import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Talk to the selected agent. GPT-Live is the voice — it listens and
/// speaks at the same time, handles interruptions, keeps the conversation
/// going — and Visor is its backend: every request it delegates goes to
/// the selected agent, on whatever model that agent runs, and the agent's
/// reply is handed back for the voice to say. So you talk to *your* agent,
/// through a voice that knows how to hold a conversation.
///
/// Protocol: one WebSocket to `wss://api.openai.com/v1/live/sessions`,
/// `session.start` with `delegation: {type: "client"}`, PCM16 at 24 kHz
/// both ways, `session.delegation.created` in, `session.commentary.append`
/// out. Uses the same OpenAI key as dictation.
@MainActor
final class LiveSession: NSObject, ObservableObject {
    static let shared = LiveSession()

    enum State: Equatable {
        case off, connecting, listening, thinking, speaking, failed(String)
        var isOn: Bool { self != .off }
    }

    static let voiceKey = "visor.live.voice"
    static let bargeInKey = "visor.live.bargeIn"
    static let model = "gpt-live-1"
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]

    @Published private(set) var state: State = .off
    /// Smoothed 0…1 levels for the meter.
    @Published private(set) var inputLevel: CGFloat = 0
    @Published private(set) var outputLevel: CGFloat = 0
    /// What you're saying, as it's heard; what the voice is saying back.
    @Published private(set) var heard = ""
    @Published private(set) var saying = ""
    @Published var muted = false {
        didSet { if muted { inputLevel = 0 } }
    }
    @Published var voice: String = UserDefaults.standard.string(forKey: LiveSession.voiceKey) ?? "marin" {
        didSet { UserDefaults.standard.set(voice, forKey: Self.voiceKey) }
    }
    /// Cut the voice off the moment you start talking over it.
    @Published var bargeIn: Bool = UserDefaults.standard.object(forKey: LiveSession.bargeInKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(bargeIn, forKey: Self.bargeInKey) }
    }

    private weak var chat: ChatController?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sinks = Set<AnyCancellable>()

    // Audio
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var inputConverter: AVAudioConverter?
    private var outbox = Data()
    private var levelTimer: Timer?
    private var inputPeak: CGFloat = 0
    private var outputPeak: CGFloat = 0
    private var outputTail: Date = .distantPast

    // The turn in flight
    private var pendingDelegation: String?
    private var turnText = ""
    private var spokenUpTo = 0
    private var lastAppendAt = Date.distantPast
    /// This turn went to the agent (its reply is the transcript's answer);
    /// otherwise the voice answered itself and its words are mirrored in.
    private var turnDelegated = false
    /// The voice's own answer, as it streams into the transcript.
    private var voiceMessageID: UUID?
    /// What the user said this turn has been written into the transcript.
    private var userTurnWritten = false

    private override init() { super.init() }

    static var hasKey: Bool { VoiceInput.hasKey }

    // MARK: Control

    func toggle(chat: ChatController) {
        if state.isOn { stop() } else { start(chat: chat) }
    }

    func start(chat: ChatController) {
        guard !state.isOn else { return }
        guard let key = Keychain.get(VoiceInput.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            state = .failed("Add an OpenAI key in Settings → Voice first.")
            return
        }
        self.chat = chat
        state = .connecting
        heard = ""; saying = ""
        observe(chat)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        receive()

        send([
            "type": "session.start",
            "event_id": "visor_start",
            "session": [
                "model": Self.model,
                "instructions": instructions(for: chat),
                "audio": [
                    "format": ["type": "audio/pcm", "rate": 24_000],
                    "output": ["voice": voice],
                ],
                "delegation": ["type": "client"],
            ],
        ])

        do { try startAudio() } catch {
            fail("Microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard state.isOn else { return }
        send(["type": "session.close"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.teardown() }
        state = .off
    }

    private func fail(_ message: String) {
        teardown()
        state = .failed(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if case .failed = self?.state { self?.state = .off }
        }
    }

    private func teardown() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        stopAudio()
        sinks.removeAll()
        if let id = voiceMessageID { chat?.liveUpdate(id: id, content: saying, final: true) }
        pendingDelegation = nil
        turnText = ""; spokenUpTo = 0
        turnDelegated = false; voiceMessageID = nil; userTurnWritten = false
        heard = ""; saying = ""
        inputLevel = 0; outputLevel = 0
    }

    /// The voice speaks for the agent; it never answers for it.
    private func instructions(for chat: ChatController) -> String {
        let name = chat.agent?.name ?? "the agent"
        return """
        You are the voice of \(name), an AI agent running in Visor on the user's Mac. \
        You do not answer questions or do tasks yourself: for anything the user asks or wants done, delegate to the backend, which is \(name), and then relay what it says. \
        Relay faithfully and completely — keep its numbers, names, file names, commands and conclusions exact; don't add advice of your own. \
        If the backend asks the user for permission or a decision, ask them plainly and wait. \
        If the backend is still working, say so briefly rather than guessing. \
        Delegate everything, greetings included — the user is talking to \(name), not to you. Be warm, brief and natural.
        """
    }

    // MARK: Socket

    private func send(_ event: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            if let error { Task { @MainActor in self?.fail("Connection: \(error.localizedDescription)") } }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    if self.state.isOn { self.fail("Connection: \(error.localizedDescription)") }
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8),
                       let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(event)
                    } else if case .data(let data) = message,
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(event)
                    }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "session.started":
            state = .listening
        case "session.output_audio.delta":
            if let b64 = event["delta"] as? String, let data = Data(base64Encoded: b64) { play(data) }
        case "session.input_transcript.delta":
            if let delta = event["delta"] as? String {
                if state == .speaking, bargeIn { interrupt() }
                // The first words after an answer start a new turn.
                if userTurnWritten || voiceMessageID != nil {
                    if let id = voiceMessageID { chat?.liveUpdate(id: id, content: saying, final: true) }
                    heard = ""; saying = ""
                    voiceMessageID = nil
                    userTurnWritten = false
                    turnDelegated = false
                }
                heard += delta
                // Your words, as they're heard, in the composer — it's your
                // turn being written.
                chat?.draft = heard
                state = .listening
            }
        case "session.output_transcript.delta":
            if let delta = event["delta"] as? String {
                // The voice is answering. Whatever was heard is your turn
                // in the transcript, delegated or not; if the voice is
                // answering by itself, its words are the agent's turn.
                writeUserTurn()
                saying += delta
                if !turnDelegated, let chat {
                    if let id = voiceMessageID {
                        chat.liveUpdate(id: id, content: saying)
                    } else {
                        voiceMessageID = chat.liveAppend(role: .assistant, content: saying)
                    }
                }
            }
        case "session.delegation.created":
            let delegation = event["delegation"] as? [String: Any]
            let id = delegation?["id"] as? String ?? event["delegation_id"] as? String
            delegate(id: id)
        case "session.closed":
            if state.isOn { state = .off; teardown() }
        case "error":
            let err = event["error"] as? [String: Any]
            let message = err?["message"] as? String ?? event["message"] as? String ?? "Live session error"
            fail(message)
        default:
            break
        }
    }

    // MARK: Delegation — the agent is the backend

    /// The voice wants the backend's answer to what was just said. The
    /// request is what we've heard since the last turn; it goes to the
    /// selected agent as a real message, and the reply streams back as
    /// commentary while it's written.
    /// What you said, into the transcript — once per turn, before any
    /// answer to it appears.
    private func writeUserTurn() {
        guard !userTurnWritten, let chat else { return }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chat.liveAppend(role: .user, content: text)
        chat.draft = ""
        userTurnWritten = true
    }

    private func delegate(id: String?) {
        guard let chat else { return }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingDelegation = id
        turnText = ""; spokenUpTo = 0
        turnDelegated = true
        state = .thinking
        // If the voice already answered part of this turn itself, that answer
        // stays; the agent's reply follows it.
        if let id = voiceMessageID { chat.liveUpdate(id: id, content: saying, final: true); voiceMessageID = nil }

        // A pending approval answered by voice: "yes" allows, "no" declines.
        if chat.pendingApproval != nil {
            let lower = text.lowercased()
            if lower.range(of: #"\b(yes|yeah|yep|allow|go ahead|do it|sure|okay|ok|approve|run it)\b"#, options: .regularExpression) != nil {
                chat.approvePending(always: false)
                return
            }
            if lower.range(of: #"\b(no|nope|don't|do not|deny|stop|cancel)\b"#, options: .regularExpression) != nil {
                chat.denyPending()
                return
            }
        }
        guard !text.isEmpty else {
            commentary("I didn't catch that.")
            return
        }
        if chat.agent == nil {
            commentary("There's no agent selected yet. Pick one in Visor first.")
            return
        }
        if userTurnWritten {
            // Already in the transcript from the voice's first words; send
            // the same text without a second copy of your turn.
            chat.liveDropLastUserTurn()
        }
        userTurnWritten = true
        chat.draft = text
        chat.send()
        if let error = chat.error, !error.isEmpty {
            commentary("The agent couldn't take that: \(error)")
        }
    }

    private func observe(_ chat: ChatController) {
        sinks.removeAll()
        chat.$conversation.map { $0.messages.last }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] last in self?.replyChanged(last) }.store(in: &sinks)
        chat.$isStreaming.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in if !on { self?.replyFinished() } }.store(in: &sinks)
        chat.$pendingApproval.receive(on: DispatchQueue.main)
            .sink { [weak self] p in if let p { self?.approvalAsked(p) } }.store(in: &sinks)
        chat.$error.receive(on: DispatchQueue.main)
            .sink { [weak self] e in if let e, !e.isEmpty, self?.pendingDelegation != nil { self?.commentary("The agent hit a problem: \(e)") } }.store(in: &sinks)
    }

    /// Stream the reply as it's written: each finished paragraph goes to
    /// the voice at once, so it can start talking before the agent is done.
    private func replyChanged(_ last: ChatMessage?) {
        guard pendingDelegation != nil, let last, last.role == .assistant else { return }
        turnText = last.content
        let text = turnText
        guard text.count > spokenUpTo else { return }
        if let cut = text.range(of: "\n\n", range: text.index(text.startIndex, offsetBy: spokenUpTo)..<text.endIndex) {
            let chunk = String(text[text.index(text.startIndex, offsetBy: spokenUpTo)..<cut.lowerBound])
            spokenUpTo = text.distance(from: text.startIndex, to: cut.upperBound)
            append(chunk)
        }
    }

    private func replyFinished() {
        guard pendingDelegation != nil, let chat else { return }
        if let last = chat.conversation.messages.last, last.role == .assistant {
            turnText = last.content
        }
        let rest = String(turnText.dropFirst(spokenUpTo)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { append(rest) }
        if turnText.isEmpty, chat.pendingApproval == nil { commentary("The agent didn't answer.") }
        spokenUpTo = turnText.count
        pendingDelegation = nil
        if state == .thinking { state = .listening }
    }

    private func approvalAsked(_ pending: ChatController.PendingApproval) {
        guard pendingDelegation != nil else { return }
        let names = pending.needing.map(\.name).joined(separator: ", ")
        let detail = pending.needing.first.map { Self.summary(of: $0) } ?? ""
        commentary("Before it goes on, \(chat?.agent?.name ?? "the agent") wants to run \(names)\(detail.isEmpty ? "" : ": \(detail)"). Ask the user whether to allow it. They can say yes or no.")
        // The delegation stays open: a yes or no arrives as the next request.
    }

    private static func summary(of call: ToolCall) -> String {
        guard let data = call.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (dict["command"] as? String) ?? (dict["path"] as? String) ?? ""
    }

    /// Hand text to the voice for the open delegation, in pieces the
    /// protocol accepts, with prose the voice can say.
    private func append(_ text: String) {
        for piece in Self.pieces(Self.speakable(text)) { commentary(piece) }
    }

    private func commentary(_ content: String) {
        var event: [String: Any] = ["type": "session.commentary.append", "content": content,
                                    "event_id": "visor_\(Int(Date().timeIntervalSince1970 * 1000))"]
        if let pendingDelegation { event["delegation_id"] = pendingDelegation }
        send(event)
        lastAppendAt = Date()
    }

    /// Markdown that would be read aloud badly, made sayable.
    static func speakable(_ text: String) -> String {
        var s = text
        // Fenced code: keep the fact of it and its first line.
        s = s.replacingOccurrences(of: #"```[a-zA-Z]*\n([^\n]*)[\s\S]*?```"#,
                                   with: "(code: $1 …)", options: .regularExpression)
        // Tables: rows become sentences.
        s = s.replacingOccurrences(of: #"^\|[-:| ]+\|$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\|(.+)\|$"#, with: "$1.", options: .regularExpression)
        s = s.replacingOccurrences(of: " | ", with: ", ")
        s = s.replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each append is limited to about five hundred tokens.
    static func pieces(_ text: String, limit: Int = 1400) -> [String] {
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var current = ""
        for sentence in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + sentence.count + 1 > limit, !current.isEmpty {
                out.append(current); current = ""
            }
            current += (current.isEmpty ? "" : "\n") + sentence
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: Audio

    private func startAudio() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        inputConverter = AVAudioConverter(from: inFormat, to: wire)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        input.installTap(onBus: 0, bufferSize: 2400, format: inFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
        player.play()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLevels() }
        }
    }

    private func stopAudio() {
        levelTimer?.invalidate(); levelTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.detach(player)
        outbox.removeAll()
    }

    /// Off the audio thread: convert to the wire format and ship ~50 ms at a time.
    private nonisolated func capture(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            guard let converter = self.inputConverter, self.state.isOn else { return }
            let ratio = self.wire.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.wire, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData?[0] else { return }
            let count = Int(out.frameLength)
            var peak: Int16 = 0
            for i in 0..<count { peak = max(peak, abs(channel[i])) }
            self.inputPeak = max(self.inputPeak, CGFloat(peak) / 32767)
            if self.muted { return }
            self.outbox.append(Data(bytes: channel, count: count * 2))
            if self.outbox.count >= 2400 {
                self.send(["type": "session.input_audio.append", "audio": self.outbox.base64EncodedString()])
                self.outbox.removeAll(keepingCapacity: true)
            }
        }
    }

    private func play(_ pcm: Data) {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        var peak: Float = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let v = Float(Int16(littleEndian: samples[i])) / 32767
                out[i] = v
                peak = max(peak, abs(v))
            }
        }
        outputPeak = max(outputPeak, CGFloat(peak))
        outputTail = Date().addingTimeInterval(Double(frames) / 24_000)
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
        state = .speaking
    }

    /// Drop whatever the voice had queued: you're talking now.
    private func interrupt() {
        player.stop()
        player.play()
        outputPeak = 0
        outputTail = .distantPast
        saying = ""
    }

    private func tickLevels() {
        inputLevel += (min(1, inputPeak * 3) - inputLevel) * 0.5
        inputPeak *= 0.6
        outputLevel += (min(1, outputPeak * 2.5) - outputLevel) * 0.5
        outputPeak *= 0.6
        if state == .speaking, Date() > outputTail {
            state = pendingDelegation == nil ? .listening : .thinking
        }
    }
}

extension LiveSession: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            if self.state.isOn, self.state != .off {
                let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "closed (\(closeCode.rawValue))"
                self.fail("Live session \(why)")
            }
        }
    }
}

// MARK: - The control and the pill

/// The Live switch beside the agent: one control in the card and the HUD.
struct LiveToggle: View {
    @ObservedObject var chat: ChatController
    @ObservedObject private var live = LiveSession.shared
    var size: CGFloat = Design.Metric.small

    var body: some View {
        IconButton(symbol: live.state.isOn ? "waveform.circle.fill" : "waveform.circle",
                   size: size,
                   tint: live.state.isOn ? Design.Retro.accent : Design.Ink.secondary,
                   active: live.state.isOn,
                   help: live.state.isOn ? "End the live conversation" : "Talk to \(chat.agent?.name ?? "the agent") — live voice") {
            live.toggle(chat: chat)
        }
        .accessibilityIdentifier("visor.live.toggle")
    }
}

/// In the composer while Live is on: the state of the conversation and a
/// level. Click it to end the conversation.
struct LiveComposerStatus: View {
    @ObservedObject var chat: ChatController
    var fontSize: CGFloat
    @ObservedObject private var live = LiveSession.shared

    var body: some View {
        Button { live.stop() } label: {
            HStack(spacing: 6) {
                StatusDot(state: dotState)
                Text(label)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(Design.Ink.tertiary)
                    .lineLimit(1)
                LevelBars(level: live.state == .speaking ? live.outputLevel : live.inputLevel,
                          tint: live.state == .speaking ? Design.Retro.accent : Design.Ink.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("End the live conversation")
        .accessibilityIdentifier("visor.live.status")
    }

    private var dotState: StatusDot.State {
        switch live.state {
        case .thinking, .speaking: return .working
        case .failed: return .absent
        default: return .idle
        }
    }

    private var label: String {
        switch live.state {
        case .off: return "Live"
        case .connecting: return "Connecting"
        case .listening: return live.muted ? "Muted" : "Listening"
        case .thinking: return "Working"
        case .speaking: return "Speaking"
        case .failed: return "Live failed"
        }
    }
}

/// The composer's mic while Live is on: lit on the accent and ringed by
/// the input level; click to mute.
struct LiveMicButton: View {
    var size: CGFloat
    @ObservedObject private var live = LiveSession.shared

    var body: some View {
        Button { live.muted.toggle() } label: {
            ZStack {
                Circle()
                    .strokeBorder(Design.Retro.accent.opacity(0.5), lineWidth: 2)
                    .scaleEffect(1 + live.inputLevel * 0.35)
                    .opacity(live.muted ? 0 : Double(0.3 + live.inputLevel * 0.7))
                Circle().fill(live.muted ? Color.white.opacity(0.1) : Design.Retro.accent)
                Image(systemName: live.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(live.muted ? Color.white.opacity(0.6) : Design.Retro.onAccent)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.visorBare)
        .focusable(false)
        .animation(.linear(duration: 0.05), value: live.inputLevel)
        .help(live.muted ? "Unmute the mic" : "Mute the mic")
    }
}

/// Five bars that follow a level.
struct LevelBars: View {
    var level: CGFloat
    var tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let threshold = CGFloat(i) / 5
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? tint : tint.opacity(0.2))
                    .frame(width: 3, height: 6 + CGFloat(i) * 2)
            }
        }
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityHidden(true)
    }
}
