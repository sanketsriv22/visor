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
        guard let i = args.firstIndex(of: "--probe-transcription") else { return false }
        let mode = args.count > i + 1 ? args[i + 1] : "eager"
        let model = args.count > i + 2 ? args[i + 2] : StreamingTranscriber.model
        Task { @MainActor in
            await run(mode: mode, model: model)
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
