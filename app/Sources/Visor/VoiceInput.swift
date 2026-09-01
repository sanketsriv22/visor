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

    /// Say something in the dictation pill — where the transcript ended up
    /// when it couldn't be typed, mostly. Dictation that silently goes nowhere
    /// is the failure this exists to prevent.
    func report(_ message: String) {
        state = .failed(message)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Only clear our own notice — the user may have started speaking
            // again, and blanking that state would strand the pill.
            if self?.state == .failed(message) { self?.state = .idle }
        }
    }
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

    /// Default chosen for the job rather than for capability.
    ///
    /// This was Haiku 4.5 — a capable mid-tier model asked to insert commas.
    /// It costs roughly twelve times as much as a small model for the same
    /// task, and being larger it is also slower, on a step that sits between
    /// someone speaking and their words appearing. The size that matters here
    /// is instruction-following, not intelligence: a model that decides to
    /// *answer* dictation instead of punctuating it has destroyed what was
    /// said, and that failure is not one the big models are meaningfully
    /// better at avoiding.
    static var cleanupModel: String {
        get { UserDefaults.standard.string(forKey: "visor.dictationCleanupModel")
                ?? "google/gemini-2.5-flash-lite" }
        set { UserDefaults.standard.set(newValue, forKey: "visor.dictationCleanupModel") }
    }

    /// What the cleanup model is told to do.
    ///
    /// Editable, and visible, because it was neither: the instruction lived in
    /// the source, so the only way to know why a transcript came back the way
    /// it did was to read the app. This is the one prompt in Visor a user has
    /// reason to tune — it runs on their words, dozens of times a day, and what
    /// counts as "cleaned up" is a matter of taste.
    ///
    /// Every clause earns its place. Naming what not to do matters more than
    /// naming what to do: a small model handed dictation will cheerfully answer
    /// it, summarise it, or translate it, and any of those silently destroys
    /// what you said.
    static let defaultCleanupPrompt = """
        You clean up dictated speech into the text the speaker meant to write. \
        Reply with that text only — never a reply, a summary, a translation, or \
        a comment.

        Fix punctuation, capitalisation, obvious mishearings, and filler words \
        ("um", "uh", "like", "you know", false starts, stutters).

        Apply spoken corrections. When someone corrects themselves, the \
        correction wins and every trace of the correction goes away — both the \
        wrong words and the phrase that flagged them. Corrections are marked by \
        things like "sorry", "I mean", "I meant", "rather", "actually", "no \
        wait", "scratch that", "let me rephrase". Replace exactly what was \
        corrected and leave the rest of the sentence alone.

        "build a machine learning model, sorry, an artificial intelligence \
        model" becomes "Build an artificial intelligence model."
        "meet on Tuesday — no wait, Wednesday" becomes "Meet on Wednesday."
        "send it to Mark, I mean Mike" becomes "Send it to Mike."
        "scratch that, let's start over: the plan is X" becomes "The plan is X."

        Change nothing else. Do not reword, reorder, improve, shorten, or add \
        anything the speaker did not say. If a sentence is already clean, \
        return it unchanged. If you are unsure whether something is a \
        correction, leave it as spoken.
        """

    static var cleanupPrompt: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "visor.dictationCleanupPrompt")
            guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return defaultCleanupPrompt }
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty prompt would leave the model with no instruction at all,
            // which doesn't disable cleanup — it makes it unpredictable.
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: "visor.dictationCleanupPrompt")
            } else {
                UserDefaults.standard.set(newValue, forKey: "visor.dictationCleanupPrompt")
            }
        }
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
        // Already granted: start immediately.
        //
        // Going through requestAccess unconditionally meant posting
        // .visorSystemPrompt every time, which drops the panel below the menu
        // bar so a permission dialog can appear above it. With permission
        // already given the callback returns within milliseconds — so the
        // panel dipped and recovered too fast to see as movement, and showed
        // as the menu bar behind it flashing through. Only step aside when a
        // dialog is actually going to appear.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .denied, .restricted:
            state = .denied
        default:
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
    }

    private func beginRecording() {
        // Where the words are going, decided now rather than when they arrive.
        // Transcription is a round trip; focus can move in between.
        TextInsertion.captureTarget()
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
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
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
        // dBFS: -160 is silence, 0 is clipping. The window matters more than it
        // sounds. Normal speech into a laptop mic averages about -40 dB and
        // peaks near -20; mapping from -45 put ordinary talking at 0.1-0.4 of
        // the scale, which is why the meter never rose past its second row.
        //
        // Peak rather than average: average is pulled down by the gaps between
        // syllables, so it under-reads exactly when someone is speaking
        // normally. Peak is what you see when you watch a voice.
        let dB = max(recorder.peakPower(forChannel: 0),
                     recorder.averagePower(forChannel: 0))
        let floor: Float = -50
        let ceiling: Float = -12
        let span = max(0, min(1, (dB - floor) / (ceiling - floor)))
        // Loudness is logarithmic and the ear is not linear, so a linear
        // mapping spends most of the meter on volumes nobody produces. The
        // curve expands the quiet end, where speech actually lives.
        let normalised = pow(span, 0.55)
        // Rise instantly, fall slowly: a meter that decays reads as a voice,
        // one that tracks exactly reads as a flicker.
        level = normalised > level ? normalised : level * 0.78 + normalised * 0.22
    }

    // MARK: - Transcription

    /// Which model turns the audio into text.
    ///
    /// Configurable because it's the half of the wait nobody looks at: the
    /// cleanup model has a picker and gets blamed, while transcription is a
    /// bigger upload and a slower service and has been a hard-coded constant.
    /// gpt-transcribe by default: faster *and* cheaper than what it replaces.
    ///
    /// whisper-1 costs $0.006 a minute and cannot stream, so nothing comes back
    /// until the whole recording has been processed. gpt-transcribe is $0.0045
    /// and can return partial results. There is no axis on which the old
    /// default was the better choice — it was simply the one that existed when
    /// this was written.
    static var transcriptionModel: String {
        get { UserDefaults.standard.string(forKey: "visor.transcriptionModel") ?? "gpt-transcribe" }
        set { UserDefaults.standard.set(newValue, forKey: "visor.transcriptionModel") }
    }

    private func transcribe(_ url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        // From the moment there's audio to send, so the measurement includes
        // the upload — which for a minute of speech is most of it.
        let transcribeStarted = Date()
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
            let cleanupStarted = Date()
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
                conversation: currentConversation?(),
                transcribeSeconds: cleanupStarted.timeIntervalSince(transcribeStarted),
                cleanupSeconds: Self.cleanupEnabled
                    ? Date().timeIntervalSince(cleanupStarted) : nil))
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
        field("model", VoiceInput.transcriptionModel)
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
