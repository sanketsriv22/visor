import Foundation

/// Version and changelog the running app reports, read from its own bundle.
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Bullet lines from the newest CHANGELOG.md section (the current version).
    static var latestChangelog: [String] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var bullets: [String] = []
        var inFirstSection = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inFirstSection { break } // hit the next version — stop
                inFirstSection = true
                continue
            }
            if inFirstSection, line.hasPrefix("- ") {
                bullets.append(String(line.dropFirst(2)))
            }
        }
        return bullets
    }
}
