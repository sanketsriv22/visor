import AVFoundation
import AppKit
import Foundation

/// `Visor --probe-transcription <eager|wait> <model>`: replay the realtime
/// transcription session exactly as `StreamingTranscriber` runs it — the
/// same session.update, 24 kHz PCM16 in 100 ms appends, the same commit —
/// against the real service with the app's own key, and write every event
/// the server sends to ~/Library/Logs/Visor/probe.log. Run from the app,
/// not a script, because only the app may read the key from the Keychain.
enum TranscriptionProbe {
    static func runIfRequested(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--probe-mic") {
            let seconds = args.count > i + 1 ? Double(args[i + 1]) ?? 6 : 6
            Task { @MainActor in
                await probeMicrophone(seconds: seconds)
                exit(0)
            }
            return true
        }
        guard let i = args.firstIndex(of: "--probe-transcription") else { return false }
        let mode = args.count > i + 1 ? args[i + 1] : "eager"
        let given = args.count > i + 2 ? args[i + 2] : nil
        Task { @MainActor in
            await run(mode: mode, model: given ?? StreamingTranscriber.model)
            exit(0)
        }
        return true
    }

    private static let log: FileHandle = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Visor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try! FileHandle(forWritingTo: url)
    }()
    private static let t0 = Date()
    private static func note(_ s: String) {
        log.write("\(String(format: "%6.2f", Date().timeIntervalSince(t0))) \(s)\n".data(using: .utf8)!)
    }

    /// `Visor --probe-mic <seconds>`: record through the app's own capture
    /// path (MicEngine, the AAC file, the same converter) while the Mac
    /// speaks a known sentence through its speakers, keep the file at
    /// ~/Library/Logs/Visor/mic-probe.m4a, and upload it as the app would.
    /// The transcript in probe.log says whether what the microphone hears
    /// survives the pipeline — no one needs to be at the keyboard.
    @MainActor
    private static func probeMicrophone(seconds: Double) async {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Visor")
        let file = dir.appendingPathComponent("mic-probe.m4a")
        try? FileManager.default.removeItem(at: file)
        note("mic probe: device \"\(MicEngine.defaultInputName())\", \(seconds) s")
        var buffers = 0, bytes = 0
        var peak: Float = 0
        do {
            try MicEngine.shared.start(file: file,
                                       onPCM: { pcm in buffers += 1; bytes += pcm.count },
                                       onPeak: { peak = max(peak, $0) },
                                       onFailure: { note("mic probe: start FAILED \($0.localizedDescription)") })
        } catch {
            note("mic probe: could not start: \(error.localizedDescription)"); return
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["testing one two three. the quick brown fox jumps over the lazy dog. four five six."]
        try? say.run()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        MicEngine.shared.stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        note("mic probe: \(buffers) buffers, \(bytes) PCM bytes = \(String(format: "%.1f", Double(bytes) / 48_000)) s at 24 kHz; peak \(String(format: "%.3f", peak)) (\(Int(20 * log10(max(peak, 0.00001)))) dBFS); file \(size) bytes")
        guard let key = Keychain.get(VoiceInput.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            note("mic probe: no key — file kept, not uploaded"); return
        }
        guard let audio = try? Data(contentsOf: file), audio.count > 1_000 else { note("mic probe: file too small"); return }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let boundary = "visor-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = VoiceInput.multipartBody(boundary: boundary, audio: audio, filename: "mic-probe.m4a")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String
            note("mic probe: upload → \(status): \(text ?? String(data: data, encoding: .utf8) ?? "?")")
        } catch {
            note("mic probe: upload failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func run(mode: String, model: String) async {
        guard let key = Keychain.get(VoiceInput.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            note("no key"); return
        }
        // Three seconds of the system voice, converted as the app converts.
        let aiff = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("visor-probe.aiff")
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "testing one two three. the quick brown fox jumps over the lazy dog."]
        try? say.run(); say.waitUntilExit()
        guard let file = try? AVAudioFile(forReading: aiff) else { note("no audio file"); return }
        let wire = MicEngine.wire
        guard let conv = AVAudioConverter(from: file.processingFormat, to: wire),
              let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { note("no converter"); return }
        try? file.read(into: inBuf)
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * wire.sampleRate / file.processingFormat.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: outCap) else { return }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        let pcm = Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * 2)
        var peak: Int16 = 0
        for i in 0..<Int(out.frameLength) { peak = max(peak, abs(out.int16ChannelData![0][i])) }
        note("audio: \(pcm.count) bytes = \(String(format: "%.2f", Double(pcm.count) / 48_000)) s, peak \(peak); mode=\(mode) model=\(model)")

        let session = URLSession(configuration: .default)
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let ws = session.webSocketTask(with: req)
        ws.resume()
        func send(_ obj: [String: Any]) {
            let d = try! JSONSerialization.data(withJSONObject: obj)
            ws.send(.string(String(data: d, encoding: .utf8)!)) { e in if let e { note("SEND ERR \(e)") } }
        }
        let update: [String: Any] = ["type": "session.update", "session": [
            "type": "transcription",
            "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24_000],
                "transcription": ["model": model],
                "noise_reduction": ["type": "near_field"],
                "turn_detection": ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 900],
            ]],
        ]]
        var ready = false
        var counts: [String: Int] = [:]
        func receive() {
            ws.receive { result in
                switch result {
                case .failure(let e): note("RECV ERR \(e)")
                case .success(let m):
                    var text = ""
                    if case .string(let s) = m { text = s }
                    if case .data(let d) = m { text = String(data: d, encoding: .utf8) ?? "" }
                    if let d = text.data(using: .utf8), let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let type = ev["type"] as? String {
                        counts[type, default: 0] += 1
                        var short = ev
                        short["delta"] = (ev["delta"] as? String).map { String($0.prefix(40)) }
                        if let s = short["session"] as? [String: Any] { short["session"] = ["id": s["id"] ?? "", "type": s["type"] ?? "", "audio": s["audio"] ?? ""] }
                        let body = (try? JSONSerialization.data(withJSONObject: short)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        note("← \(type) \(body.prefix(400))")
                        if !ready, type == "session.created" || type == "session.updated" || type.hasPrefix("transcription_session") {
                            ready = true
                            if mode == "wait" { send(update) }
                        }
                    }
                    receive()
                }
            }
        }
        receive()
        if mode == "eager" { send(update) }
        var waited = 0.0
        while !ready && waited < 3 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 0.05 }
        note("ready=\(ready); streaming")
        var offset = 0
        while offset < pcm.count {
            let chunk = pcm.subdata(in: offset..<min(offset + 4_800, pcm.count))
            send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
            offset += 4_800
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        note("sent all audio; 2 s, then commit")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        send(["type": "input_audio_buffer.commit"])
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        note("events: " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        ws.cancel(with: .normalClosure, reason: nil)
        try? log.synchronize()
    }
}
