import AVFoundation
import CoreAudio
import Foundation

/// The one microphone path. A single `AVAudioEngine` kept for the life of
/// the app: opening the audio device is the slow part of starting to
/// listen, and a fresh engine per dictation paid it every time — the
/// half-second between the key and the pill. Kept prepared between
/// dictations, restarts are quick.
///
/// Every buffer is converted once to 16-bit mono PCM at 24 kHz and goes
/// three ways: to the streaming transcriber, to the fallback file on
/// disk (AAC, so the upload path needs no second recorder), and to the
/// meter as a peak.
@MainActor
final class MicEngine {
    static let shared = MicEngine()

    static let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var onPCM: ((Data) -> Void)?
    private var onPeak: ((Float) -> Void)?

    /// Loudest sample as 0…1. Widened before the absolute value: a fully
    /// clipped sample is -32768, `abs` of which does not fit in Int16 and
    /// trapped — one loud click into the microphone took the app down.
    nonisolated static func peak(_ samples: UnsafePointer<Int16>, _ count: Int) -> Float {
        var peak: Int32 = 0
        for i in 0..<count { peak = max(peak, abs(Int32(samples[i]))) }
        return Float(peak) / 32767
    }
    private(set) var running = false
    /// Which start() is in flight, so a stop() that lands first wins.
    private var generation = 0
    /// Every engine call — prepare, start, stop — goes through here, in
    /// order. A stop's prepare() racing the next start() on another queue
    /// is the kind of thing that leaves an engine that delivers nothing.
    private let audio = DispatchQueue(label: "visor.mic", qos: .userInteractive)
    private var written = 0

    private init() {}

    /// The system's default input device, by name — the one the engine's
    /// input node follows. Logged at every start, because a Continuity
    /// iPhone microphone or a Bluetooth set quietly becoming the default
    /// is the difference between a transcript and Korean fragments.
    nonisolated static func defaultInputName() -> String {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return "none" }
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, ptr)
        }
        return status == noErr ? (name as String) : "device \(device)"
    }

    enum MicError: LocalizedError {
        case noInput, unsupportedFormat
        var errorDescription: String? {
            switch self {
            case .noInput:           return "No microphone is available right now"
            case .unsupportedFormat: return "The microphone's format can't be converted"
            }
        }
    }

    /// Get the device ready without turning the mic on.
    func warm() {
        _ = engine.inputNode
        engine.prepare()
    }

    /// Open and close the device once, so the first real start is tens of
    /// milliseconds rather than the 650+ a cold engine took — long enough
    /// that a short first press after launch ended before a single buffer
    /// arrived, and the recording was empty. Only when nothing is running
    /// and permission is already granted; the mic indicator blinks once.
    ///
    /// Set up exactly as `start()` sets up — the input node touched and a
    /// tap on it, on the main thread, before the engine is prepared. A
    /// bare prepare() on a nodeless engine raises an ObjC exception (which
    /// nothing in Swift can catch) and took build 479 down at launch.
    func warmUpDevice() {
        guard !running, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            DictationLog.note("mic: no input device to warm"); return
        }
        let engine = self.engine
        audio.async {
            let began = Date()
            var note: String
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2400, format: format) { _, _ in }
            do {
                engine.prepare()
                try engine.start()
                engine.stop()
                note = "mic: warmed the device in \(Int(Date().timeIntervalSince(began) * 1000)) ms"
            } catch {
                note = "mic: warm-up failed: \(error.localizedDescription)"
            }
            input.removeTap(onBus: 0)        // after the stop, on this queue
            Task { @MainActor in DictationLog.note(note) }
        }
    }

    /// Opens the device off the main thread — `AVAudioEngine.start()` takes
    /// a few hundred milliseconds the first time and tens after, and on the
    /// main thread that was the pill waiting to paint. `onFailure` is called
    /// on the main thread if the device can't be opened.
    func start(file url: URL?, onPCM: @escaping (Data) -> Void, onPeak: @escaping (Float) -> Void,
               onFailure: @escaping (Error) -> Void) throws {
        if running {
            // Never reuse a previous session's closures: they point at a
            // transcriber that is gone.
            DictationLog.note("mic: start while running — stopping first")
            stop()
        }
        written = 0
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        // A 0 Hz format is what the node reports with no input device (one
        // just unplugged, a Bluetooth set mid-switch). Installing a tap
        // with it raises an ObjC exception — "required condition is
        // false" — which no Swift catch sees; AppKit swallowed it, the
        // press logged "arm" and nothing more, and the concurrency
        // runtime's thread state was left corrupt, so the next button or
        // menu click crashed in assumeIsolated. Refuse it here instead.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            DictationLog.note("mic: no input device (format \(Int(inFormat.sampleRate)) Hz/\(inFormat.channelCount) ch)")
            throw MicError.noInput
        }
        guard let converter = AVAudioConverter(from: inFormat, to: Self.wire) else {
            DictationLog.note("mic: no converter from \(Int(inFormat.sampleRate)) Hz/\(inFormat.channelCount) ch")
            throw MicError.unsupportedFormat
        }
        self.converter = converter
        if let url {
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ], commonFormat: .pcmFormatInt16, interleaved: true)
        }
        self.onPCM = onPCM
        self.onPeak = onPeak
        running = true
        generation += 1
        let gen = generation
        let engine = self.engine
        DictationLog.note("mic: start gen=\(gen) device=\"\(Self.defaultInputName())\" format=\(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch file=\(url?.lastPathComponent ?? "none")")
        // The tap goes on here, on the audio queue, in order with any stop
        // or warm-up still finishing there: the engine's graph is not for
        // two threads to edit at once.
        audio.async {
            input.removeTap(onBus: 0)        // a warm-up's, if one is still there; a no-op otherwise
            input.installTap(onBus: 0, bufferSize: 2400, format: inFormat) { [weak self] buffer, _ in
                self?.capture(buffer)
            }
            do {
                engine.prepare()
                try engine.start()
                Task { @MainActor in
                    if gen != self.generation || !self.running {
                        DictationLog.note("mic: started gen=\(gen) but stopped meanwhile — closing")
                        self.audio.async { engine.stop() }
                    } else {
                        DictationLog.note("mic: running gen=\(gen)")
                    }
                }
            } catch {
                Task { @MainActor in
                    DictationLog.note("mic: start FAILED gen=\(gen): \(error.localizedDescription)")
                    guard gen == self.generation else { return }
                    self.stop()
                    onFailure(error)
                }
            }
        }
    }

    func stop() {
        generation += 1
        let was = running
        running = false
        file = nil          // closes and flushes
        onPCM = nil; onPeak = nil
        DictationLog.note("mic: stop (was \(was ? "running" : "idle"), \(written) bytes written)")
        let engine = self.engine
        // Unconditional, in order with any start still in flight: stopping
        // a stopped engine is free, and the generation check closes a start
        // that lands after this.
        // The tap comes off *after* the engine has stopped, on the audio
        // queue. Removing it from the main thread while the IO thread was
        // still inside it called a freed block: a segfault on
        // com.apple.audio.IOThread the moment a dictation ended.
        audio.async {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.prepare()
        }
    }

    private nonisolated func capture(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            guard self.running, let converter = self.converter else { return }
            let ratio = Self.wire.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.wire, frameCapacity: capacity) else { return }
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
            self.onPeak?(Self.peak(channel, count))
            do { try self.file?.write(from: out) } catch {
                if self.written == 0 { DictationLog.note("mic: file write failed: \(error.localizedDescription)") }
            }
            self.written += count * 2
            self.onPCM?(Data(bytes: channel, count: count * 2))
        }
    }
}
