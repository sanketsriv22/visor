import AVFoundation
import Foundation

/// Transcription that keeps pace with speech.
///
/// The old path recorded to a file, then uploaded the whole thing, then
/// waited for the whole transcript — nothing began until you stopped
/// talking, so a long dictation paid for all of it at the end. This one
/// opens a realtime transcription session the moment you start and
/// streams the microphone to it as 16-bit PCM in 100 ms pieces. The
/// service's voice-activity detection closes a segment at each pause and
/// transcribes it *while you keep talking*; the segments are stitched in
/// order. Releasing the key commits only the phrase in flight, so the
/// wait after key-up is the last phrase's, whatever the total length.
/// That is how Wispr Flow feels instant on a twenty-minute dictation.
///
/// The one thing turn detection must not do is cut a sentence at a
/// breath, so the silence it waits for is long (900 ms) and the pieces
/// are joined with a space, not a full stop.
///
/// Fidelity is the same model family as before (`gpt-transcribe`) and
/// slightly better in one respect: the file path re-encoded the mic to
/// AAC at 16 kHz; this sends raw PCM at 24 kHz.
@MainActor
final class StreamingTranscriber: NSObject {
    /// Partial text so far, as the model revises it; `final` when done.
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// 0…1 peak of the last chunk, for the meter.
    var onLevel: ((Float) -> Void)?

    private(set) var isOpen = false
    private(set) var text = ""
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var ready = false
    private var queued: [String] = []
    private var committed = false
    private var finished = false
    private var closeTimer: DispatchWorkItem?
    /// Segments in the order the service opened them, by item id, with
    /// their text so far and whether they are done.
    private var order: [String] = []
    private var segments: [String: (text: String, done: Bool)] = [:]
    /// Audio has been sent since the last segment closed, so key-up has
    /// something to commit.
    private var audioSinceCut = false
    private var sentBytes = 0

    private var outbox = Data()

    /// The realtime models that support turn detection, which the phrase-
    /// by-phrase path needs (`gpt-transcribe`, the file model, does not).
    /// Mini is $0.003 a minute — a third less than the file path's
    /// $0.0045 — and quicker; the full model is $0.006 and a little more
    /// accurate on hard audio. Settings → Voice → Speed chooses.
    static let models: [(id: String, title: String)] = [
        ("gpt-4o-mini-transcribe", "Mini — $0.003/min, fastest"),
        ("gpt-4o-transcribe", "Full — $0.006/min, most accurate"),
    ]
    static var model: String {
        get { UserDefaults.standard.string(forKey: "visor.streamingModel") ?? "gpt-4o-mini-transcribe" }
        set { UserDefaults.standard.set(newValue, forKey: "visor.streamingModel") }
    }

    /// Open the session. Audio arrives through `feed`.
    func start(key: String, model: String? = nil, prompt: String? = nil) throws {
        guard !isOpen else { return }
        let model = model ?? Self.model
        text = ""; ready = false; queued = []; committed = false; finished = false
        order = []; segments = [:]; audioSinceCut = false; sentBytes = 0
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        isOpen = true
        receive()
        var transcription: [String: Any] = ["model": model]
        if let prompt, !prompt.isEmpty { transcription["prompt"] = prompt }
        send([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "noise_reduction": ["type": "near_field"],
                        // Each pause closes a segment the service transcribes
                        // while you go on talking. A long silence, so a breath
                        // mid-sentence doesn't end one.
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 900,
                        ],
                    ],
                ],
            ],
        ])
    }

    /// Stop the microphone; commit the phrase in flight, if there is one,
    /// and wait for every open segment to finish.
    func finish() {
        guard isOpen, !committed else { return }
        committed = true
        flush(force: true)
        if audioSinceCut { send(["type": "input_audio_buffer.commit"]) }
        settleIfDone()
        // If a final never arrives, hand over what we have rather than hang.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.onFinal?(self.stitched)
            self.close()
        }
        closeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Everything so far, in order: finished segments and the one in flight.
    private var stitched: String {
        order.compactMap { segments[$0]?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// After key-up, the transcript is final once nothing is uncommitted
    /// and no segment is still being transcribed.
    private func settleIfDone() {
        guard committed, !finished, !audioSinceCut else { return }
        guard !order.contains(where: { segments[$0]?.done == false }) else { return }
        finished = true
        closeTimer?.cancel()
        onFinal?(stitched)
        close()
    }

    /// Drop everything.
    func cancel() {
        close()
    }

    private func close() {
        closeTimer?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        isOpen = false
    }

    // MARK: Socket

    private func send(_ event: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: event),
              let string = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(string)) { [weak self] error in
            if let error { Task { @MainActor in self?.fail("Connection: \(error.localizedDescription)") } }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                switch result {
                case .failure(let error):
                    if !self.finished { self.fail(error.localizedDescription) }
                case .success(let message):
                    var data: Data?
                    if case .string(let s) = message { data = s.data(using: .utf8) }
                    if case .data(let d) = message { data = d }
                    if let data, let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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
        case "session.updated", "session.created", "transcription_session.updated", "transcription_session.created":
            if !ready {
                ready = true
                // Audio captured before the session was ready goes now.
                for chunk in queued { send(["type": "input_audio_buffer.append", "audio": chunk]) }
                queued.removeAll()
            }
        case "input_audio_buffer.committed", "conversation.item.created":
            // A segment closed (by the service's VAD, or by our commit): a
            // new item that will now be transcribed.
            if let id = (event["item_id"] as? String) ?? ((event["item"] as? [String: Any])?["id"] as? String) {
                open(id)
            }
            if type == "input_audio_buffer.committed" { audioSinceCut = false }
        case _ where type.hasSuffix("transcription.delta"):
            if let delta = event["delta"] as? String {
                let id = (event["item_id"] as? String) ?? order.last ?? "item"
                open(id)
                segments[id]?.text += delta
                text = stitched
                onPartial?(text)
            }
        case _ where type.hasSuffix("transcription.completed") || type.hasSuffix("transcription.done"):
            let id = (event["item_id"] as? String) ?? order.last ?? "item"
            open(id)
            let full = (event["transcript"] as? String) ?? (event["text"] as? String) ?? segments[id]?.text ?? ""
            segments[id] = (full, true)
            text = stitched
            onPartial?(text)
            settleIfDone()
        case "input_audio_buffer.speech_started":
            audioSinceCut = true
        case "error":
            let err = event["error"] as? [String: Any]
            let message = err?["message"] as? String ?? "Transcription failed"
            // A commit with nothing new in the buffer is not a failure: the
            // last phrase already closed on its own.
            if committed, message.lowercased().contains("buffer") {
                audioSinceCut = false
                settleIfDone()
                return
            }
            fail(message)
        default:
            break
        }
    }

    private func open(_ id: String) {
        if segments[id] == nil {
            segments[id] = ("", false)
            order.append(id)
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        close()
        onFailure?(message)
    }

    // MARK: Audio

    /// 16-bit mono PCM at 24 kHz, from the shared microphone engine.
    func feed(_ pcm: Data) {
        guard isOpen, !committed else { return }
        outbox.append(pcm)
        audioSinceCut = true
        flush(force: false)
    }

    /// Ship 100 ms at a time (4,800 bytes at 24 kHz mono 16-bit).
    private func flush(force: Bool) {
        guard force || outbox.count >= 4_800 else { return }
        guard !outbox.isEmpty else { return }
        let chunk = outbox.base64EncodedString()
        outbox.removeAll(keepingCapacity: true)
        if ready { send(["type": "input_audio_buffer.append", "audio": chunk]) } else { queued.append(chunk) }
    }
}

extension StreamingTranscriber: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            guard self.isOpen, !self.finished else { return }
            let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "closed (\(closeCode.rawValue))"
            self.fail("Transcription session \(why)")
        }
    }
}
