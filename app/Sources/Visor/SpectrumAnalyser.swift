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
    /// Where the sound is coming from: -1 hard left, 0 centre, +1 hard right.
    ///
    /// A MacBook's microphones are an array, so the same voice reaches them at
    /// different levels depending on which side of the machine you're on. That
    /// difference is small — a few dB — so it's exaggerated on the way out, and
    /// heavily smoothed: a pan that jitters is worse than no pan at all.
    @Published private(set) var balance: Float = 0
    /// Whether there are two channels to compare. With one, `balance` stays at
    /// centre rather than inventing a direction.
    @Published private(set) var stereo = false

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
    /// Per-band noise floor, in dB, learned from the room.
    private var floors: [Float]

    init() {
        bands = Array(repeating: 0, count: Self.bandCount)
        floors = Array(repeating: -30, count: Self.bandCount)
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
        let channels = Int(format.channelCount)
        Task { @MainActor in self.stereo = channels >= 2 }

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Self.fftSize),
                         format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let magnitudes = Self.analyse(samples: data[0], count: count,
                                          window: self.window, setup: self.fft)
            guard let magnitudes else { return }

            // Which side is louder, as a ratio rather than a difference, so it
            // means the same thing whether you're whispering or shouting.
            var pan: Float = 0
            if channels >= 2 {
                let left = Self.energy(data[0], count: count)
                let right = Self.energy(data[1], count: count)
                let total = left + right
                if total > 1e-6 { pan = (right - left) / total }
            }
            Task { @MainActor in
                self.absorb(magnitudes)
                self.absorb(pan: pan)
            }
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
        balance = 0
        // Re-learned next time: the room is not the same room it was.
        floors = Array(repeating: -30, count: Self.bandCount)
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
        let usable = magnitudes.count

        for band in 0..<Self.bandCount {
            // Logarithmic band edges: pitch is logarithmic, so linear bands
            // give thirty bars of hiss and two of voice.
            let low = Self.edge(band, of: Self.bandCount, bins: usable)
            let high = max(low + 1, Self.edge(band + 1, of: Self.bandCount, bins: usable))
            var sum: Float = 0
            for bin in low..<min(high, usable) { sum += magnitudes[bin] }
            // Scaled by the window length. vDSP's forward transform is
            // unnormalised, so without this the magnitudes are a thousand times
            // larger than they should be and every band pegs at full — which is
            // exactly what a silent room looked like.
            let mean = sum / Float(high - low) / Float(Self.fftSize)
            let dB = 20 * log10(max(mean, 1e-9))

            // Each band learns its own floor. Room tone is not flat — a fan is
            // low, a fridge hums, a laptop hisses — so one threshold across the
            // spectrum either buries a voice or lights the bands the room is
            // already filling.
            if dB < floors[band] {
                floors[band] = dB
            } else {
                floors[band] += 0.02
            }
            let above = dB - (floors[band] + 6)
            let value = max(0, min(1, above / 34))

            // Rise instantly, fall quickly. Heavier smoothing made every
            // syllable linger into the next one, so the border read as a slow
            // swell rather than as speech.
            bands[band] = value > bands[band]
                ? value
                : bands[band] * 0.45 + value * 0.55
        }
    }

    private nonisolated static func energy(_ samples: UnsafePointer<Float>,
                                           count: Int) -> Float {
        var total: Float = 0
        vDSP_measqv(samples, 1, &total, vDSP_Length(count))
        return total
    }

    /// Exaggerated and smoothed. The raw difference between two microphones a
    /// few inches apart is a couple of dB; left alone it would never move the
    /// picture, and unsmoothed it would twitch on every syllable.
    private func absorb(pan: Float) {
        let widened = max(-1, min(1, pan * 3.5))
        // Still smoothed, but less: direction should follow you turning your
        // head, not arrive several seconds later.
        balance = balance * 0.8 + widened * 0.2
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
