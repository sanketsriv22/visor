import AVFoundation
import Foundation

/// Push-to-talk dictation through OpenAI's transcription API.
///
/// This needs its own key: OpenRouter is a chat-completions gateway and does
/// not proxy audio transcription, so the OpenRouter key every chat agent
/// shares can't be reused here.
///
/// One microphone engine (`MicEngine`) feeds three things at once: the
/// `StreamingTranscriber`, which receives words while you speak so
/// releasing the key leaves only the last phrase to finish; an AAC file
/// on disk, uploaded the old way if the stream fails for any reason; and
/// the meter. Nothing is lost either way, and the pill shows the moment
/// the key is heard, before the device has even opened.
@MainActor
final class VoiceInput: NSObject, ObservableObject {
    /// Stream while speaking (fast) or upload the file afterwards (the old
    /// way). Kept as a switch so the two can be compared on the same Mac.
    static var streamingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "visor.dictationStreaming") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "visor.dictationStreaming") }
    }

    /// The transcript so far, while it is still being spoken.
    @Published private(set) var partial = ""
    /// The microphone is open and streaming but nothing shows yet — the
    /// first 180 ms of a press, before it's known to be a hold.
    private(set) var armed = false
    private var streamer: StreamingTranscriber?
    private var streamFailed = false
    private var streamNote: String?
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
    /// The listening animation's simulation, ticked from the same sampler that
    /// reads the level so the two never drift apart.
    let arcade = VoiceArcade()
    let pong = VoicePong()

    /// The recent past of that level, oldest first.
    ///
    /// Held here rather than in the view because two views draw it: the meter
    /// on each side of the notch is one wave, and they have to be reading the
    /// same samples or the halves won't line up as it passes behind.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 28)

    /// The last buffer's peak, in dBFS.
    private var peakDB: Float = -80
    private var meterTimer: Timer?
    private var fileURL: URL?
    private var startedAt: Date?
    /// Running estimate of the room's own noise, in dBFS.
    private var noiseFloor: Float = -40
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

    /// Whether this transcript is worth a second round trip.
    ///
    /// Cleanup was written for whisper-1, which returns words and little
    /// punctuation. The current transcription models punctuate as they go, so
    /// for a short clean sentence the pass costs about a second and changes
    /// nothing — a third of the total wait, spent confirming there was nothing
    /// to do.
    ///
    /// It still runs whenever there is something to fix: a spoken correction, a
    /// filler word, or text that came back without any sentence punctuation.
    /// The test is deliberately generous — missing a correction is much worse
    /// than a wasted call — and long transcripts always go through, since the
    /// chance of nothing needing attention across several sentences is slim.
    static func needsCleanup(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count >= 12 else { return false }
        guard raw.count <= 240 else { return true }

        let lower = " " + raw.lowercased() + " "
        let markers = ["sorry", "i mean", "i meant", "rather", "actually",
                       "no wait", "scratch that", "rephrase", "correction",
                       " um ", " uh ", " erm ", " like like ", " you know ",
                       " i i ", " the the ", " a a "]
        if markers.contains(where: { lower.contains($0) }) { return true }

        // No sentence punctuation at all is the whisper-1 signature.
        return !raw.contains(where: { ".!?".contains($0) })
    }

    /// The Design Lab's: show a state without a microphone.
    func previewState(_ preview: State) { state = preview }

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

    /// Open the microphone without showing anything: a press has begun and
    /// may be a tap. `start()` then shows the pill over the same capture;
    /// `cancel()` drops it.
    func arm() {
        guard state == .idle, !armed else { return }
        guard Self.hasKey, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        armed = true
        openMicrophone()
    }

    func start() {
        if armed {
            // Already capturing since the key went down; now show it.
            armed = false
            state = .recording
            startMetering()
            return
        }
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

    /// Opens the connection to the transcription service while you're still
    /// talking.
    ///
    /// The measured cost of transcribing is almost all fixed: 96 seconds of
    /// speech took 3.7s and 7 seconds took 2.8s, so it is setup, not audio. A
    /// good part of that setup is DNS, TCP and a TLS handshake that only begins
    /// once there is a file to send — while the user waits.
    ///
    /// It can happen during the recording instead. This request is thrown away;
    /// the point is the connection it leaves in URLSession's pool, which the
    /// real upload then reuses.
    private func warmConnection() {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        Task { _ = try? await URLSession.shared.data(for: request) }
    }

    private func beginRecording() {
        openMicrophone()
        // The pill first. The device takes a moment to open; the person
        // shouldn't wait on it to know the key was heard.
        state = .recording
        startMetering()
    }

    /// The capture itself: the file, the stream, the engine. Shows nothing.
    private func openMicrophone() {
        // Where the words are going, decided now rather than when they arrive.
        // Transcription is a round trip; focus can move in between.
        TextInsertion.captureTarget()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("visor-dictation-\(UUID().uuidString).m4a")
        fileURL = url
        startedAt = Date()
        if Self.streamingEnabled { beginStream() } else { warmConnection() }
        do {
            try MicEngine.shared.start(file: url,
                                       onPCM: { [weak self] pcm in self?.streamer?.feed(pcm) },
                                       onPeak: { [weak self] peak in
                                           self?.peakDB = 20 * log10(max(peak, 0.00001))
                                       },
                                       onFailure: { [weak self] error in
                                           guard let self, self.state == .recording || self.armed else { return }
                                           self.stopMetering()
                                           self.streamer?.cancel(); self.streamer = nil
                                           self.armed = false
                                           self.state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
                                       })
        } catch {
            stopMetering()
            streamer?.cancel(); streamer = nil
            armed = false
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    /// Stop recording and transcribe what was captured.
    func finish() {
        guard state == .recording else { return }
        stopMetering()
        MicEngine.shared.stop()
        guard let url = fileURL else { state = .idle; return }
        state = .transcribing
        finishedAt = Date()
        if let streamer, streamer.isOpen, !streamFailed {
            // The words are mostly here already; ask for the rest.
            streamer.finish()
        } else {
            Task { await transcribe(url) }
        }
    }

    // MARK: - Streaming

    /// Open the realtime session as recording begins. Anything that goes
    /// wrong — no session, a dropped socket, an error event — falls back
    /// to the file upload, which is still being written.
    private func beginStream() {
        guard let key = Keychain.get(Self.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        let t = StreamingTranscriber()
        streamFailed = false
        partial = ""
        t.onPartial = { [weak self] text in self?.partial = text }
        t.onFinal = { [weak self] text in
            guard let self else { return }
            let started = self.startedAt
            self.streamer = nil
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            self.fileURL = nil
            self.deliver(raw: text, transcribeSeconds: self.finishedAt.map { Date().timeIntervalSince($0) } ?? 0,
                         startedAt: started, path: "stream")
        }
        t.onFailure = { [weak self] why in
            guard let self else { return }
            self.streamFailed = true
            self.streamNote = why
            self.streamer = nil
            // Still recording: the file path takes over at finish(). Already
            // finishing: upload the file now.
            if self.state == .transcribing, let url = self.fileURL {
                Task { await self.transcribe(url) }
            }
            NSLog("[Visor] streaming transcription failed, using upload: %@", why)
        }
        do {
            // The realtime session needs a model that supports turn detection;
            // the file model setting stays what it is for the upload path.
            try t.start(key: key, model: StreamingTranscriber.model)
            streamer = t
        } catch {
            streamFailed = true
            streamNote = error.localizedDescription
        }
    }

    /// When finish() was called — the stream's wait is measured from here,
    /// the upload's from when the file was ready; both are "after key-up".
    private var finishedAt: Date?

    /// One place the transcript lands, from either path: cleanup if it
    /// needs it, the log, the caller.
    private func deliver(raw: String, transcribeSeconds: TimeInterval, startedAt: Date?, path: String) {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { state = .idle; partial = ""; return }
        Task { @MainActor in
            var trimmed = raw
            let cleanupStarted = Date()
            var cleaned = false
            if Self.cleanupEnabled, Self.needsCleanup(raw), let polish {
                cleaned = true
                trimmed = await polish(raw)
            }
            state = .idle
            partial = ""
            VoiceLog.append(VoiceEntry(
                text: trimmed,
                duration: startedAt.map { cleanupStarted.timeIntervalSince($0) },
                conversation: currentConversation?(),
                transcribeSeconds: transcribeSeconds,
                path: path,
                note: path == "upload" ? streamNote : nil,
                cleanupSeconds: cleaned ? Date().timeIntervalSince(cleanupStarted) : nil))
            self.startedAt = nil
            streamNote = nil
            onTranscript?(trimmed)
        }
    }

    /// Abandon a recording without transcribing it.
    func cancel() {
        stopMetering()
        streamer?.cancel()
        streamer = nil
        partial = ""
        armed = false
        MicEngine.shared.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
        state = .idle
    }

    // MARK: - Metering

    private func startMetering() {
        // Re-measured each time: the room is not the same room it was.
        noiseFloor = -40
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 50, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLevel() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        levels = Array(repeating: 0, count: levels.count)
        arcade.reset()
        pong.reset()
    }

    private func sampleLevel() {
        guard state == .recording else { return }
        // dBFS: -160 is silence, 0 is clipping. The window matters more than it
        // sounds. Normal speech into a laptop mic averages about -40 dB and
        // peaks near -20; mapping from -45 put ordinary talking at 0.1-0.4 of
        // the scale, which is why the meter never rose past its second row.
        //
        // Peak rather than average: average is pulled down by the gaps between
        // syllables, so it under-reads exactly when someone is speaking
        // normally. Peak is what you see when you watch a voice.
        // Buffers arrive about twenty times a second and the meter samples
        // fifty; reading "silence" between them collapsed the noise floor and
        // lit the meter on room noise. Hold the last reading instead.
        let dB = peakDB

        // The floor is measured, not assumed.
        //
        // A fixed floor is what kept the middle rows lit in silence: a quiet
        // room still reads around -50 dBFS, and mapping from -50 through a
        // curve that expands the quiet end turned that into a third of the
        // scale. The meter was faithfully displaying the sound of the room.
        //
        // This follows the quietest thing it has heard, dropping to it at once
        // and creeping back up slowly, so it settles on the room's own noise
        // wherever you are and doesn't mistake a pause for silence.
        if dB < noiseFloor {
            noiseFloor = dB
        } else {
            noiseFloor += 0.02
        }

        // Nothing registers until it is clearly above that floor, so an empty
        // room reads as empty.
        // Five, not eight: enough to clear the room, little enough that a
        // normal speaking voice is well up the scale rather than scraping in.
        let floor = noiseFloor + 5
        let ceiling: Float = -12
        guard ceiling > floor else { level = 0; levels.removeFirst(); levels.append(0); return }
        let span = max(0, min(1, (dB - floor) / (ceiling - floor)))
        // Loudness is logarithmic and the ear is not linear, so a linear
        // mapping spends most of the meter on volumes nobody produces. Gentler
        // than it was: the old curve lifted near-silence to a third of full
        // scale on its own.
        let normalised = pow(span, 0.7)
        // Rise instantly, fall slowly: a meter that decays reads as a voice,
        // one that tracks exactly reads as a flicker.
        // Falls quickly. A slow decay meant a single syllable stayed lit as it
        // travelled the whole grid, so the meter read as lagging behind the
        // voice rather than following it.
        level = normalised > level ? normalised : level * 0.6 + normalised * 0.4
        levels.removeFirst()
        levels.append(level)

        arcade.tick(delta: 1.0 / 50, level: level)
        pong.tick(delta: 1.0 / 50, level: level)
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
            deliver(raw: text, transcribeSeconds: Date().timeIntervalSince(transcribeStarted), startedAt: startedAt,
                    path: Self.streamingEnabled ? "upload" : "upload (streaming off)")
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
