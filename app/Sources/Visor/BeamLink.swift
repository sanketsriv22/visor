import Foundation

/// Encodes a note into a shareable "Beam" link and back.
///
/// The note's markdown is deflated and base64url-encoded into the URL *fragment*
/// (the part after `#`). Browsers never send the fragment to the server, so the
/// landing page — and whoever hosts it — never sees the note's contents. The
/// page's only job is to hand the fragment off to the `visor://` scheme, which
/// the app decodes locally. No backend, no account, nothing stored anywhere.
enum BeamLink {
    /// Static handoff page. The note rides in the fragment, so this host only
    /// ever serves a fixed page — it never receives the note data.
    static let base = "https://sanketsriv22.github.io/visor/beam/"
    static let scheme = "visor"

    /// Build a shareable link that encodes `markdown`, or nil if encoding fails.
    static func link(forMarkdown markdown: String) -> String? {
        guard let encoded = encode(markdown) else { return nil }
        return base + "#" + encoded
    }

    /// Pull the payload out of any beam URL (the https page or a `visor://` link)
    /// and decode it back to markdown.
    static func markdown(fromURL url: URL) -> String? {
        let s = url.absoluteString
        guard let hash = s.firstIndex(of: "#") else { return nil }
        let fragment = String(s[s.index(after: hash)...])
        return decode(fragment)
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
