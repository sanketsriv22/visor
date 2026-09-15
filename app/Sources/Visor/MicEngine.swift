import AVFoundation
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
    private(set) var running = false
    /// Which start() is in flight, so a stop() that lands first wins.
    private var generation = 0

    private init() {}

    /// Get the device ready without turning the mic on.
    func warm() {
        _ = engine.inputNode
        engine.prepare()
    }

    /// Opens the device off the main thread — `AVAudioEngine.start()` takes
    /// a few hundred milliseconds the first time and tens after, and on the
    /// main thread that was the pill waiting to paint. `onFailure` is called
    /// on the main thread if the device can't be opened.
    func start(file url: URL?, onPCM: @escaping (Data) -> Void, onPeak: @escaping (Float) -> Void,
               onFailure: @escaping (Error) -> Void) throws {
        guard !running else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: Self.wire)
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
        input.installTap(onBus: 0, bufferSize: 2400, format: inFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        running = true
        generation += 1
        let gen = generation
        let engine = self.engine
        DispatchQueue.global(qos: .userInteractive).async {
            do {
                engine.prepare()
                try engine.start()
                Task { @MainActor in
                    // Stopped before the device opened: close it again.
                    if gen != self.generation || !self.running { engine.stop() }
                }
            } catch {
                Task { @MainActor in
                    guard gen == self.generation else { return }
                    self.stop()
                    onFailure(error)
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        generation += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        file = nil          // closes and flushes
        onPCM = nil; onPeak = nil
        // Ready for the next one.
        let engine = self.engine
        DispatchQueue.global(qos: .utility).async { engine.prepare() }
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
            var peak: Int16 = 0
            for i in 0..<count { peak = max(peak, abs(channel[i])) }
            self.onPeak?(Float(peak) / 32767)
            try? self.file?.write(from: out)
            self.onPCM?(Data(bytes: channel, count: count * 2))
        }
    }
}
