import AVFoundation
import Foundation

/// Transcription that keeps pace with speech.
///
/// The old path recorded to a file, then uploaded the whole thing, then
/// waited for the whole transcript — nothing began until you stopped
/// talking, so a long dictation paid for all of it at the end. This one
/// opens a realtime transcription session the moment you start, streams
/// the microphone to it as 16-bit PCM in 100 ms pieces, and receives the
/// words while you are still speaking. Releasing the key sends one
/// commit; what's left to wait for is the last second or so of audio.
/// That is how Wispr Flow feels instant on a two-minute dictation.
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

    private let engine = AVAudioEngine()
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var outbox = Data()

    static let model = "gpt-transcribe"

    /// Open the session and start streaming the microphone.
    func start(key: String, model: String = StreamingTranscriber.model, prompt: String? = nil) throws {
        guard !isOpen else { return }
        text = ""; ready = false; queued = []; committed = false; finished = false
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
                        // We end the turn ourselves, on key-up; the model
                        // must not cut a sentence at a pause.
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ])
        try startAudio()
    }

    /// Stop the microphone and ask for the final transcript.
    func finish() {
        guard isOpen, !committed else { return }
        committed = true
        stopAudio()
        flush(force: true)
        send(["type": "input_audio_buffer.commit"])
        // If nothing final arrives, hand over what we have rather than hang.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.onFinal?(self.text)
            self.close()
        }
        closeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Drop everything.
    func cancel() {
        stopAudio()
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
        case _ where type.hasSuffix("transcription.delta"):
            if let delta = event["delta"] as? String {
                text += delta
                onPartial?(text)
            }
        case _ where type.hasSuffix("transcription.completed") || type.hasSuffix("transcription.done"):
            let full = (event["transcript"] as? String) ?? (event["text"] as? String) ?? text
            text = full
            if committed, !finished {
                finished = true
                closeTimer?.cancel()
                onFinal?(full)
                close()
            } else {
                onPartial?(full)
            }
        case "error":
            let err = event["error"] as? [String: Any]
            fail(err?["message"] as? String ?? "Transcription failed")
        default:
            break
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        stopAudio()
        close()
        onFailure?(message)
    }

    // MARK: Audio

    private func startAudio() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: wire)
        input.installTap(onBus: 0, bufferSize: 2400, format: inFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func stopAudio() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private nonisolated func capture(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            guard let converter = self.converter, self.isOpen, !self.committed else { return }
            let ratio = self.wire.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: self.wire, frameCapacity: capacity) else { return }
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
            self.onLevel?(Float(peak) / 32767)
            self.outbox.append(Data(bytes: channel, count: count * 2))
            self.flush(force: false)
        }
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
