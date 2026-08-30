import AVFoundation
import Foundation

/// Push-to-talk dictation through OpenAI's transcription API.
///
/// This needs its own key: OpenRouter is a chat-completions gateway and does
/// not proxy audio transcription, so the OpenRouter key every chat agent
/// shares can't be reused here.
///
/// Recording uses `AVAudioRecorder` rather than `AVAudioEngine`. The engine
/// would mean owning format conversion and buffer plumbing to get a file
/// Whisper accepts; the recorder writes AAC straight to disk and hands us
/// metering for free, which is all the level display needs.
@MainActor
final class VoiceInput: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case denied
        case recording
        case transcribing
        case failed(String)

        var isBusy: Bool { self == .recording || self == .transcribing }
    }

    /// Keychain account for the transcription key, separate from the chat key.
    static let keyAccount = "OpenAI (voice)"

    @Published private(set) var state: State = .idle
    /// Smoothed 0…1 input level, for the meter.
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var fileURL: URL?
    private var startedAt: Date?
    /// Set by the owner so a logged utterance records where it went.
    var currentConversation: (() -> UUID?)?
    /// Called with the transcript when one arrives.
    var onTranscript: ((String) -> Void)?
    /// Optional tidy-up pass over the raw transcript.
    ///
    /// Whisper returns what was said, which is not the same as what you meant
    /// to write: no punctuation to speak of, filler words, and the occasional
    /// homophone. A cheap model fixes that for a fraction of a cent. Runs
    /// before logging, so the log holds the version you'd actually send.
    var polish: ((String) async -> String)?

    /// Whether the tidy-up pass runs.
    static var cleanupEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "visor.dictationCleanup") }
        set { UserDefaults.standard.set(newValue, forKey: "visor.dictationCleanup") }
    }

    static var cleanupModel: String {
        get { UserDefaults.standard.string(forKey: "visor.dictationCleanupModel")
                ?? "anthropic/claude-haiku-4.5" }
        set { UserDefaults.standard.set(newValue, forKey: "visor.dictationCleanupModel") }
    }

    static var hasKey: Bool {
        guard let k = Keychain.get(keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return !k.isEmpty
    }

    // MARK: - Control

    func toggle() {
        switch state {
        case .recording: finish()
        case .transcribing: break          // let it land
        default: start()
        }
    }

    func start() {
        guard Self.hasKey else {
            state = .failed("Add an OpenAI key in Settings to dictate")
            return
        }
        // Asking every time is cheap and handles the user revoking access.
        // Step the notch down first: it draws above the menu bar, which means
        // it draws above this dialog too.
        NotificationCenter.default.post(name: .visorSystemPrompt, object: nil,
                                        userInfo: ["showing": true])
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                NotificationCenter.default.post(name: .visorSystemPrompt, object: nil,
                                                userInfo: ["showing": false])
                guard let self else { return }
                guard granted else { self.state = .denied; return }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("visor-dictation-\(UUID().uuidString).m4a")
        // 16 kHz mono is what the model wants anyway; recording higher just
        // makes a bigger upload for no accuracy.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.record() else {
                state = .failed("Couldn't start the microphone")
                return
            }
            self.recorder = recorder
            self.fileURL = url
            self.startedAt = Date()
            state = .recording
            startMetering()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop recording and transcribe what was captured.
    func finish() {
        guard state == .recording, let recorder else { return }
        stopMetering()
        recorder.stop()
        self.recorder = nil
        guard let url = fileURL else { state = .idle; return }
        state = .transcribing
        Task { await transcribe(url) }
    }

    /// Abandon a recording without transcribing it.
    func cancel() {
        stopMetering()
        recorder?.stop()
        recorder = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        state = .idle
    }

    // MARK: - Metering

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLevel() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func sampleLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // averagePower is dBFS: -160 (silence) to 0 (clipping). Speech mostly
        // lives in the top 45 dB, so map that range across the meter instead of
        // the full scale, where normal talking would barely move it.
        let dB = recorder.averagePower(forChannel: 0)
        let normalised = max(0, min(1, (dB + 45) / 45))
        // Ease upward fast and fall slowly, so the meter reads as a voice
        // rather than flickering per frame.
        level = normalised > level ? normalised : level * 0.75 + normalised * 0.25
    }

    // MARK: - Transcription

    private func transcribe(_ url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let key = Keychain.get(Self.keyAccount), !key.isEmpty else {
            state = .failed("Add an OpenAI key in Settings to dictate")
            return
        }
        guard let audio = try? Data(contentsOf: url), audio.count > 1_000 else {
            // Anything this small is a mis-tap, not speech.
            state = .idle
            return
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let boundary = "visor-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(boundary: boundary, audio: audio,
                                              filename: url.lastPathComponent)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                state = .failed(Self.reason(from: data) ?? "Transcription failed (\(status))")
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["text"] as? String else {
                state = .failed("Couldn't read the transcript")
                return
            }
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { state = .idle; return }

            var trimmed = raw
            if Self.cleanupEnabled, let polish {
                // Still .transcribing while this runs — from the outside it's
                // one step, and the pill shouldn't flicker between two.
                trimmed = await polish(raw)
            }
            state = .idle
            // Logged whether or not anything is listening for it: a transcript
            // that only ever existed in a composer you then closed is gone.
            VoiceLog.append(VoiceEntry(
                text: trimmed,
                duration: startedAt.map { Date().timeIntervalSince($0) },
                conversation: currentConversation?()))
            startedAt = nil
            onTranscript?(trimmed)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func multipartBody(boundary: String, audio: Data, filename: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("model", "whisper-1")
        // Nudges the model away from inventing punctuation-only output on very
        // short clips.
        field("response_format", "json")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/m4a\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private static func reason(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}

extension VoiceInput: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.state = .failed(error?.localizedDescription ?? "Recording failed")
            self.stopMetering()
        }
    }
}
