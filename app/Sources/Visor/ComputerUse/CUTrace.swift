import AppKit
import Foundation

/// Records a computer-use run to disk, step by step, so a run can be inspected
/// after the fact instead of debugged blind: the exact screenshot the model saw,
/// the Accessibility element list it was given, the raw reply it sent back, and
/// the action we then took. Traces live under Application Support and can be
/// pulled off the machine for analysis.
///
/// On by default while the feature is being built; turn off with the
/// `visor.cu.trace` default set to false.
@MainActor
final class CUTrace {
    static let enabledKey = "visor.cu.trace"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    let dir: URL?

    init(task: String) {
        guard Self.isEnabled,
              let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
        else { dir = nil; return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let d = base.appendingPathComponent("Visor/cu-traces/\(f.string(from: Date()))",
                                            isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        write("task.txt", task.isEmpty ? "(empty)" : task)
    }

    /// What the model saw and said this step.
    func turn(_ step: Int, png: Data, appName: String, model: String,
              elements: String, request: String, response: String) {
        guard let dir else { return }
        let p = String(format: "%02d", step)
        try? png.write(to: dir.appendingPathComponent("\(p)-screen.png"))
        write("\(p)-turn.txt", """
        APP: \(appName)
        MODEL: \(model)

        ===== ELEMENTS =====
        \(elements)

        ===== REQUEST =====
        \(request)

        ===== RAW RESPONSE =====
        \(response)
        """)
    }

    /// What we actually did this step.
    func action(_ step: Int, _ text: String) {
        write(String(format: "%02d-action.txt", step), text)
    }

    func finish(_ message: String) {
        write("result.txt", message)
    }

    private func write(_ name: String, _ text: String) {
        guard let dir else { return }
        try? text.data(using: .utf8)?.write(to: dir.appendingPathComponent(name))
    }
}
