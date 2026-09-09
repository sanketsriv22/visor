import AVFoundation
import Foundation

/// The introduction's voice and sound.
///
/// HeyClicky's tutorial is narrated: a voice says what is about to happen
/// while it draws, and the pace of the tour is the pace of the speech.
/// This does the same with the system's best English voice, and adds a
/// few quiet synthesised cues — a rise for the reveal, a tick for a beat,
/// a two-note chime for a success — so moments land in the ear as well as
/// the eye. Both can be muted; the preference persists.
@MainActor
final class Narrator: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let voiceKey = "visor.intro.voice"
    static let soundKey = "visor.intro.sound"

    @Published var voiceOn: Bool = UserDefaults.standard.object(forKey: Narrator.voiceKey) as? Bool ?? true {
        didSet { if !silent { UserDefaults.standard.set(voiceOn, forKey: Self.voiceKey) }; if !voiceOn { synth.stopSpeaking(at: .immediate) } }
    }
    @Published var soundOn: Bool = UserDefaults.standard.object(forKey: Narrator.soundKey) as? Bool ?? true {
        didSet { if !silent { UserDefaults.standard.set(soundOn, forKey: Self.soundKey) } }
    }
    /// What is being said right now, for the caption.
    @Published private(set) var line: String = ""
    @Published private(set) var speaking = false

    private let synth = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var completion: (() -> Void)?
    private var fallbackTimer: DispatchWorkItem?
    /// The utterance in flight, so a cancel from the mute switch continues
    /// the tour while a cancel from `stop()` does not.
    private var current: AVSpeechUtterance?
    private let voice: AVSpeechSynthesisVoice?
    /// A narrator that never makes a sound and never touches preferences —
    /// the Design Lab's.
    let silent: Bool

    init(silent: Bool = false) {
        self.silent = silent
        // The best English voice installed: premium, then enhanced, then
        // whatever the system has. Siri voices aren't offered to apps.
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            switch v.quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        }
        let preferred = ["Ava", "Zoe", "Evan", "Samantha", "Daniel", "Karen", "Moira"]
        voice = english.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) > rank(b) }
            let ia = preferred.firstIndex { a.name.hasPrefix($0) } ?? 99
            let ib = preferred.firstIndex { b.name.hasPrefix($0) } ?? 99
            return ia < ib
        }.first
        super.init()
        synth.delegate = self
        if silent { voiceOn = false; soundOn = false }
    }

    /// Say these lines in order, showing each as the caption, then call
    /// `then`. Muted, the caption still shows and the beat still waits about
    /// as long as the line would take to hear.
    func say(_ lines: [String], then: @escaping () -> Void) {
        stop()
        queue = lines
        completion = then
        next()
    }

    /// A caption without speech, for the Design Lab.
    func show(_ text: String) { line = text }

    func stop() {
        fallbackTimer?.cancel()
        queue.removeAll()
        completion = nil
        current = nil
        synth.stopSpeaking(at: .immediate)
        speaking = false
    }

    private func next() {
        guard !queue.isEmpty else {
            speaking = false
            let done = completion
            completion = nil
            done?()
            return
        }
        let text = queue.removeFirst()
        line = text
        speaking = true
        if voiceOn {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = 0.47
            utterance.pitchMultiplier = 1.0
            utterance.volume = 0.9
            utterance.postUtteranceDelay = 0.45
            current = utterance
            synth.speak(utterance)
        } else {
            let seconds = 0.9 + Double(text.count) * 0.055
            let work = DispatchWorkItem { [weak self] in self?.next() }
            fallbackTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.current else { return }
            self.current = nil
            self.next()
        }
    }

    /// Muted mid-line: carry on at reading speed rather than stall.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.current else { return }
            self.current = nil
            let seconds = 0.6
            let work = DispatchWorkItem { [weak self] in self?.next() }
            self.fallbackTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    // MARK: Cues

    enum Cue { case reveal, beat, success, stop }

    func play(_ cue: Cue) {
        guard soundOn else { return }
        SoundCues.shared.play(cue)
    }
}

/// Small synthesised sounds, generated once and played through one engine.
/// No files to bundle; nothing to license; and they match the accent's
/// character — soft, pure, brief.
final class SoundCues {
    static let shared = SoundCues()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [Narrator.Cue: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.5
        buffers[.reveal]  = render(duration: 1.6) { t in
            // A slow rise: two partials sweeping up with a soft attack.
            let f = 220.0 + 330.0 * min(1, t / 1.2)
            let env = min(1, t / 0.5) * exp(-max(0, t - 0.9) * 2.4)
            return (sin(2 * .pi * f * t) * 0.6 + sin(2 * .pi * f * 2.01 * t) * 0.25) * env * 0.35
        }
        buffers[.beat]    = render(duration: 0.28) { t in
            let env = exp(-t * 18)
            return sin(2 * .pi * 880 * t) * env * 0.22
        }
        buffers[.success] = render(duration: 1.1) { t in
            // Two notes a fifth apart, the second entering a beat later.
            let a = sin(2 * .pi * 659.25 * t) * exp(-t * 3.2)
            let b = t > 0.16 ? sin(2 * .pi * 987.77 * (t - 0.16)) * exp(-(t - 0.16) * 2.8) : 0
            return (a * 0.5 + b * 0.5) * 0.4
        }
        buffers[.stop]    = render(duration: 0.5) { t in
            let env = exp(-t * 7)
            return sin(2 * .pi * 392 * t) * env * 0.3
        }
    }

    private func render(duration: Double, _ sample: (Double) -> Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let v = Float(sample(Double(i) / format.sampleRate))
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        return buffer
    }

    func play(_ cue: Narrator.Cue) {
        guard let buffer = buffers[cue] else { return }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
}
