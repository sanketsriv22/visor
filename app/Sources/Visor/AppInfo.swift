import Foundation

/// Version and changelog the running app reports, read from its own bundle.
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// One released version and its changes.
    struct Release {
        let title: String        // the "## …" heading, e.g. "1.0-beta.1 — 2026-06-18"
        let bullets: [String]
    }

    /// CHANGELOG.md parsed into per-release sections, newest first — so the
    /// menu can show each release as its own group rather than one merged list.
    static var releases: [Release] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var sections: [Release] = []
        var title: String?
        var bullets: [String] = []
        func flush() {
            if let title { sections.append(Release(title: title, bullets: bullets)) }
            title = nil; bullets = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if title != nil, line.hasPrefix("- ") {
                bullets.append(String(line.dropFirst(2)))
            }
        }
        flush()
        return sections
    }
}
