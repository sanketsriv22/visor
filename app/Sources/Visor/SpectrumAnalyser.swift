import Accelerate
import AVFoundation
import Foundation

/// Real frequency bands from the microphone, for the edge visualiser.
///
/// The level meter has only ever had one number — `AVAudioRecorder` reports
/// loudness and nothing else — which is fine for a row of dots and useless for
/// a spectrum. Bars driven from a single amplitude all move together however
/// they're dressed up, and everyone can tell.
///
/// So this taps the input separately and runs an FFT over it. A vowel and a
/// consonant genuinely look different, which is the entire point of the thing.
///
/// Deliberately independent of the recorder. It's a second, read-only client of
/// the same device, started only when the visualiser is on, and every failure
/// path is silent — a decorative feature must never be able to take dictation
/// down with it.
@MainActor
final class SpectrumAnalyser: ObservableObject {
    /// Band energies, 0…1, low frequencies first.
    @Published private(set) var bands: [Float]

    private let engine = AVAudioEngine()
    private var running = false

    /// Enough bars to read as a spectrum, few enough that each is wide enough
    /// to see across a screen.
    static let bandCount = 64
    /// Power-of-two window. 1024 samples at 48 kHz is about 21 ms — short
    /// enough to feel immediate, long enough to resolve speech.
    private static let fftSize = 1024
    private static let log2n = vDSP_Length(10)

    private var fft: FFTSetup?
    private var window: [Float]

    init() {
        bands = Array(repeating: 0, count: Self.bandCount)
        window = [Float](repeating: 0, count: Self.fftSize)
        // Hann, or the edges of each window produce spectral splatter that
        // shows up as every band twitching at once.
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        fft = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let fft { vDSP_destroy_fftsetup(fft) }
    }

    func start() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A device reporting no channels is one we can't read; bail rather than
        // trap inside AVAudioEngine.
        guard format.channelCount > 0, format.sampleRate > 0 else { return }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Self.fftSize),
                         format: format) { [weak self] buffer, _ in
            guard let self, let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let magnitudes = Self.analyse(samples: samples, count: count,
                                          window: self.window, setup: self.fft)
            guard let magnitudes else { return }
            Task { @MainActor in self.absorb(magnitudes) }
        }

        do {
            try engine.start()
            running = true
        } catch {
            // Silent: the dots still work, dictation still works, and a
            // decorative strip is not worth an error in someone's face.
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        bands = Array(repeating: 0, count: Self.bandCount)
    }

    /// One window of samples, windowed and transformed. Runs on the audio
    /// thread, so it allocates nothing it can avoid and touches no state.
    private nonisolated static func analyse(samples: UnsafePointer<Float>, count: Int,
                                            window: [Float], setup: FFTSetup?) -> [Float]? {
        guard let setup, count >= fftSize else { return nil }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!,
                                            imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: fftSize / 2) { reinterpreted in
                        vDSP_ctoz(reinterpreted, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        return magnitudes
    }

    /// Fold the transform into bars.
    private func absorb(_ magnitudes: [Float]) {
        var next = [Float](repeating: 0, count: Self.bandCount)
        let usable = magnitudes.count

        for band in 0..<Self.bandCount {
            // Logarithmic band edges: pitch is logarithmic, so linear bands
            // give thirty bars of hiss and two of voice.
            let low = Self.edge(band, of: Self.bandCount, bins: usable)
            let high = max(low + 1, Self.edge(band + 1, of: Self.bandCount, bins: usable))
            var sum: Float = 0
            for bin in low..<min(high, usable) { sum += magnitudes[bin] }
            let mean = sum / Float(high - low)
            // Into decibels, then onto 0…1 across the range a voice occupies.
            let dB = 20 * log10(max(mean, 1e-7))
            next[band] = max(0, min(1, (dB + 52) / 46))
        }

        // Rise fast, fall slowly — the decay is what makes bars look like they
        // are dancing rather than flickering.
        for index in 0..<Self.bandCount {
            let target = next[index]
            bands[index] = target > bands[index]
                ? target
                : bands[index] * 0.72 + target * 0.28
        }
    }

    private static func edge(_ band: Int, of count: Int, bins: Int) -> Int {
        let fraction = Double(band) / Double(count)
        // 40 Hz to about 8 kHz, which is where speech lives.
        let minimum = 40.0
        let maximum = 8000.0
        let frequency = minimum * pow(maximum / minimum, fraction)
        let nyquist = 24000.0
        return max(0, min(bins - 1, Int(frequency / nyquist * Double(bins))))
    }
}
