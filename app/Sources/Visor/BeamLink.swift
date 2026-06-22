import Foundation

/// Encodes a note into a shareable "Beam" link and back.
///
/// There are two kinds of beam link, both carried in the URL *fragment* (the
/// part after `#`, which browsers never send to the server):
///
///   1. **Shared (live)** — `#s/<id>/<token>`. References a note synced through
///      the backend; opening it joins the live document so edits flow both ways.
///      This is what `NotesStore.share` now produces.
///   2. **Legacy (offline copy)** — a base64url blob of the deflated markdown.
///      The note rode entirely inside the link; opening it dropped a one-time
///      copy. Still decoded here so links shared before live sync keep working.
///
/// Either way the landing page only hands the fragment to the `visor://` scheme;
/// the host never sees note contents.
enum BeamLink {
    /// Static handoff page (kitalabs.dev, served via Firebase Hosting). The
    /// fragment never reaches this host — it only redirects to the `visor://`
    /// scheme. Links shared before this still work via their original hosts.
    static let base = "https://www.kitalabs.dev/visor/beam/"
    static let scheme = "visor"
    /// Marks a fragment as a shared-note reference rather than legacy content.
    private static let sharedPrefix = "s/"

    /// Build a link to a live shared note. The id is the whole capability now —
    /// no separate token (it was never enforced).
    static func sharedLink(for ref: BeamRef) -> String {
        base + "#" + sharedPrefix + ref.id
    }

    /// Build a legacy offline-copy link that encodes `markdown`, or nil on failure.
    static func link(forMarkdown markdown: String) -> String? {
        guard let encoded = encode(markdown) else { return nil }
        return base + "#" + encoded
    }

    /// The shared-note reference in `url`, if it's a live link. Accepts both the
    /// new `s/<id>` form and the legacy `s/<id>/<token>` form (id is the first
    /// segment either way).
    static func sharedRef(fromURL url: URL) -> BeamRef? {
        guard let fragment = fragment(of: url), fragment.hasPrefix(sharedPrefix) else { return nil }
        let rest = fragment.dropFirst(sharedPrefix.count)
        let id = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? String(rest)
        guard !id.isEmpty else { return nil }
        return BeamRef(id: id)
    }

    /// Decode a legacy offline-copy link back to markdown. Returns nil for shared
    /// links (use `sharedRef(fromURL:)` for those) or anything undecodable.
    static func markdown(fromURL url: URL) -> String? {
        guard let fragment = fragment(of: url), !fragment.hasPrefix(sharedPrefix) else { return nil }
        return decode(fragment)
    }

    private static func fragment(of url: URL) -> String? {
        let s = url.absoluteString
        guard let hash = s.firstIndex(of: "#") else { return nil }
        return String(s[s.index(after: hash)...])
    }

    // MARK: - Codec

    static func encode(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let z = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        return base64url(z)
    }

    static func decode(_ fragment: String) -> String? {
        guard let data = dataFromBase64url(fragment),
              let z = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
        return String(data: z, encoding: .utf8)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dataFromBase64url(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        let pad = b.count % 4
        if pad > 0 { b += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: b)
    }
}
