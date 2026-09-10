import AVFoundation
import AppKit
import Combine
import SwiftUI

/// The introduction's script: every line it can say, by id. The text is the
/// caption and the fallback for a system voice; the id names a bundled
/// clip (`Resources/narration/<voice>/<id>.m4a`), rendered ahead of time
/// with a neural voice by `scripts/narration.py` — the same way HeyClicky
/// ships its lines as audio rather than asking the Mac to read them.
enum Narration {
    struct Line: Equatable {
        let id: String
        let text: String
        init(_ id: String, text: String? = nil) {
            self.id = id
            self.text = text ?? Narration.script[id] ?? id
        }
    }

    static let script: [String: String] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("narration.json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }()

    /// A voice the narrator can use: one of the bundled neural voices, or any
    /// voice installed on the Mac.
    struct Voice: Identifiable, Equatable {
        enum Kind: Equatable { case bundled(folder: String), system(identifier: String) }
        let kind: Kind
        let name: String
        let detail: String

        var id: String {
            switch kind {
            case .bundled(let folder): return "visor:\(folder)"
            case .system(let identifier): return "system:\(identifier)"
            }
        }

        static func from(id: String) -> Voice? {
            if id.hasPrefix("visor:") {
                let folder = String(id.dropFirst(6))
                return bundled.first { if case .bundled(let f) = $0.kind { return f == folder }; return false }
            }
            if id.hasPrefix("system:") {
                let identifier = String(id.dropFirst(7))
                guard let v = AVSpeechSynthesisVoice(identifier: identifier) else { return nil }
                return Voice(kind: .system(identifier: identifier), name: v.name, detail: Self.quality(v))
            }
            return nil
        }

        /// The bundled voices, in the order they're offered. Only the ones
        /// whose clips actually shipped are listed.
        static let bundled: [Voice] = {
            let all: [(String, String, String)] = [
                ("heart", "Heart", "warm, American"),
                ("sky", "Sky", "clear, American"),
                ("george", "George", "measured, British"),
                ("michael", "Michael", "easy, American"),
                ("emma", "Emma", "bright, British"),
            ]
            return all.compactMap { folder, name, detail in
                guard let root = Bundle.main.resourceURL?.appendingPathComponent("narration/\(folder)"),
                      FileManager.default.fileExists(atPath: root.appendingPathComponent("intro.hi.m4a").path)
                else { return nil }
                return Voice(kind: .bundled(folder: folder), name: name, detail: detail)
            }
        }()

        /// The Mac's English voices, best first: premium, enhanced, then the
        /// compact ones that ship by default.
        static var system: [Voice] {
            AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en") }
                .filter { !$0.name.contains("(") }
                .sorted { rank($0) == rank($1) ? $0.name < $1.name : rank($0) < rank($1) }
                .map { Voice(kind: .system(identifier: $0.identifier), name: $0.name, detail: quality($0)) }
        }

        private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.quality { case .premium: return 0; case .enhanced: return 1; default: return 2 }
        }

        static func quality(_ v: AVSpeechSynthesisVoice) -> String {
            let region = Locale.current.localizedString(forRegionCode: String(v.language.suffix(2))) ?? v.language
            switch v.quality {
            case .premium:  return "\(region) · premium"
            case .enhanced: return "\(region) · enhanced"
            default:        return "\(region) · compact"
            }
        }

        /// The default: the first bundled voice, else the best system voice.
        static var preferred: Voice {
            if let v = bundled.first { return v }
            return system.first ?? Voice(kind: .system(identifier: ""), name: "Default", detail: "")
        }
    }
}

/// How loud the voice is right now, 0…1, thirty times a second — so the
/// mark and the notch can breathe with it. Its own object, so only the
/// glow redraws at that rate.
@MainActor
final class VoiceMeter: ObservableObject {
    @Published private(set) var level: CGFloat = 0
    private var timer: Timer?
    private var source: (() -> CGFloat)?
    private var target: CGFloat = 0

    func follow(_ source: @escaping () -> CGFloat) {
        self.source = source
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func release() {
        source = nil
    }

    private func tick() {
        target = source?() ?? 0
        // Quick up, slow down: speech attacks fast and trails off.
        level += (target - level) * (target > level ? 0.55 : 0.18)
        if source == nil, level < 0.01 {
            level = 0
            timer?.invalidate()
            timer = nil
        }
    }
}

/// The voice of the introduction. Says lines in order, one at a time, and
/// calls back when they have all been heard — the tour's clock. Bundled
/// clips play as audio; a system voice speaks the text; muted, each line
/// shows for about as long as it would take to hear.
@MainActor
final class Narrator: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let voiceKey = "visor.intro.voice"
    static let voiceOnKey = "visor.intro.voiceOn"
    static let soundKey = "visor.intro.sound"

    @Published var voiceOn: Bool = UserDefaults.standard.object(forKey: Narrator.voiceOnKey) as? Bool ?? true {
        didSet {
            if !silent { UserDefaults.standard.set(voiceOn, forKey: Self.voiceOnKey) }
            if !voiceOn { interrupt() }
        }
    }
    @Published var soundOn: Bool = UserDefaults.standard.object(forKey: Narrator.soundKey) as? Bool ?? true {
        didSet { if !silent { UserDefaults.standard.set(soundOn, forKey: Self.soundKey) } }
    }
    /// What is being said right now, for the caption.
    @Published private(set) var line: String = ""
    /// A second, smaller line under the caption — the reason something failed.
    @Published var detail: String? = nil
    @Published private(set) var speaking = false

    var voice: Narration.Voice {
        didSet { if !silent { UserDefaults.standard.set(voice.id, forKey: Self.voiceKey) } }
    }
    let meter = VoiceMeter()

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [Narration.Line] = []
    private var completion: (() -> Void)?
    private var fallbackTimer: DispatchWorkItem?
    private var current: AVSpeechUtterance?
    /// The voice a Settings preview is using, so its second line matches.
    private var previewVoice: Narration.Voice?
    /// A narrator that never makes a sound and never touches preferences —
    /// the Design Lab's.
    let silent: Bool

    static var savedVoice: Narration.Voice {
        (UserDefaults.standard.string(forKey: voiceKey)).flatMap(Narration.Voice.from(id:)) ?? .preferred
    }

    init(silent: Bool = false) {
        self.silent = silent
        self.voice = Narrator.savedVoice
        super.init()
        synth.delegate = self
        if silent { voiceOn = false; soundOn = false }
    }

    /// Say these lines in order, showing each as the caption, then call `then`.
    func say(_ lines: [Narration.Line], then: @escaping () -> Void) {
        stop()
        queue = lines
        completion = then
        next()
    }

    func say(_ ids: [String], then: @escaping () -> Void) {
        say(ids.map { Narration.Line($0) }, then: then)
    }

    /// A caption without speech, for the Design Lab.
    func show(_ text: String) { line = text }

    /// Hear a voice, in Settings.
    func preview(_ voice: Narration.Voice) {
        stop()
        speaking = true
        speakOrPlay(Narration.Line("intro.hi"), using: voice)
        previewVoice = voice
        queue = [Narration.Line("intro.notch")]
        completion = { [weak self] in self?.previewVoice = nil }
    }

    func stop() {
        fallbackTimer?.cancel()
        queue.removeAll()
        completion = nil
        previewVoice = nil
        interrupt()
        detail = nil
    }

    /// Stop the sound without dropping the queue: the mute switch.
    private func interrupt() {
        current = nil
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        speaking = false
        meter.release()
        if !queue.isEmpty || completion != nil { wait(0.5) }
    }

    private func next() {
        guard !queue.isEmpty else {
            speaking = false
            let done = completion
            completion = nil
            done?()
            return
        }
        let item = queue.removeFirst()
        line = item.text
        speaking = true
        if voiceOn || previewVoice != nil {
            speakOrPlay(item, using: previewVoice ?? voice)
        } else {
            wait(0.9 + Double(item.text.count) * 0.055)
        }
    }

    private func wait(_ seconds: TimeInterval) {
        fallbackTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.next() }
        fallbackTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func speakOrPlay(_ item: Narration.Line, using voice: Narration.Voice) {
        if case .bundled(let folder) = voice.kind,
           let url = Bundle.main.resourceURL?.appendingPathComponent("narration/\(folder)/\(item.id).m4a"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.delegate = self
            player.volume = 1
            player.isMeteringEnabled = true
            self.player = player
            player.play()
            meter.follow { [weak player] in
                guard let player, player.isPlaying else { return 0 }
                player.updateMeters()
                let db = player.averagePower(forChannel: 0)
                return max(0, min(1, (CGFloat(db) + 42) / 38))
            }
            return
        }
        let utterance = AVSpeechUtterance(string: item.text)
        if case .system(let identifier) = voice.kind { utterance.voice = AVSpeechSynthesisVoice(identifier: identifier) }
        utterance.rate = 0.47
        utterance.volume = 0.9
        utterance.postUtteranceDelay = 0.35
        current = utterance
        synth.speak(utterance)
        // No meter on the system synthesiser: a plausible cadence instead.
        let started = Date()
        meter.follow { [weak self] in
            guard let self, self.speaking else { return 0 }
            let t = Date().timeIntervalSince(started)
            return CGFloat(0.35 + 0.3 * sin(t * 8.3) * sin(t * 2.1) + 0.15 * sin(t * 13.7))
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.player = nil
            self.meter.release()
            self.wait(0.35)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.current else { return }
            self.current = nil
            self.meter.release()
            self.next()
        }
    }

    // MARK: Cues

    enum Cue { case reveal, beat, success, stop }

    func play(_ cue: Cue) {
        guard soundOn, !silent else { return }
        SoundCues.shared.play(cue)
    }
}

/// Four small sounds, synthesised so nothing has to be bundled: a soft
/// rise for the reveal, a tick for a beat, a two-note lift for a success,
/// a low thud for a stop.
final class SoundCues {
    static let shared = SoundCues()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var buffers: [Narrator.Cue: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    private init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.5
        buffers[.reveal] = tone([(330, 0.0), (440, 0.18), (660, 0.36)], length: 0.7, attack: 0.15, decay: 0.5)
        buffers[.beat] = tone([(880, 0.0)], length: 0.09, attack: 0.005, decay: 0.08)
        buffers[.success] = tone([(523, 0.0), (784, 0.12)], length: 0.45, attack: 0.01, decay: 0.3)
        buffers[.stop] = tone([(110, 0.0)], length: 0.3, attack: 0.005, decay: 0.28)
    }

    func play(_ cue: Narrator.Cue) {
        guard let buffer = buffers[cue] else { return }
        if !engine.isRunning { try? engine.start() }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    private func tone(_ notes: [(Double, Double)], length: Double, attack: Double, decay: Double) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(length * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            var sample = 0.0
            for (freq, start) in notes where t >= start {
                let local = t - start
                let env = min(1, local / attack) * exp(-local / decay)
                sample += sin(2 * .pi * freq * local) * env * 0.35
                sample += sin(2 * .pi * freq * 2 * local) * env * 0.08
            }
            data[i] = Float(sample)
        }
        return buffer
    }
}
