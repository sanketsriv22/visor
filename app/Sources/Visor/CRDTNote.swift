#if canImport(Automerge)
import Automerge
import Foundation

/// A note as an Automerge CRDT. The entire serialized markdown (title line
/// included — exactly the string `NotesStore` reads and writes) lives in one
/// Automerge `Text` object under the root key `"md"`. Storing it as character-
/// addressable text — rather than a single overwritten string — is what lets two
/// people edit the same note at once: concurrent insertions and deletions merge
/// per-character instead of one device's save clobbering the other's.
///
/// The document is created with the default `.unicodeScalar` text encoding, so
/// all splice offsets below are in unicode scalars.
final class CRDTNote {
    let doc: Document
    private let textObj: ObjId

    private static let key = "md"

    /// A fresh document seeded with `markdown`.
    init(markdown: String) {
        doc = Document()
        textObj = try! doc.putObject(obj: ObjId.ROOT, key: Self.key, ty: .Text)
        try? doc.spliceText(obj: textObj, start: 0, delete: 0, value: markdown)
    }

    /// Rehydrate from a compacted snapshot produced by `save()`. Throws if the
    /// bytes aren't a valid Automerge document or lack the expected text object.
    init(snapshot: Data) throws {
        doc = try Document(snapshot)
        if case let .Object(id, .Text)? = try doc.get(obj: ObjId.ROOT, key: Self.key) {
            textObj = id
        } else {
            // A snapshot without our text object is unusable as a note; create
            // the object so the instance is still well-formed (empty note).
            textObj = try doc.putObject(obj: ObjId.ROOT, key: Self.key, ty: .Text)
        }
    }

    /// The note's current markdown.
    var markdown: String { (try? doc.text(obj: textObj)) ?? "" }

    /// The current version vector — pass the value captured *before* local edits
    /// to `encodeChangesSince` to get just those edits as a delta.
    func heads() -> Set<ChangeHash> { doc.heads() }

    /// Replace the text with `new` using the smallest splice that does it: keep
    /// the common prefix and suffix, splice only the middle. This preserves the
    /// CRDT identity of untouched characters, so a remote edit elsewhere in the
    /// note still merges cleanly instead of fighting a full-text overwrite.
    func setMarkdown(_ new: String) {
        let old = markdown
        guard old != new else { return }
        let oldS = Array(old.unicodeScalars)
        let newS = Array(new.unicodeScalars)

        var prefix = 0
        let maxPrefix = min(oldS.count, newS.count)
        while prefix < maxPrefix && oldS[prefix] == newS[prefix] { prefix += 1 }

        var suffix = 0
        let maxSuffix = min(oldS.count, newS.count) - prefix
        while suffix < maxSuffix && oldS[oldS.count - 1 - suffix] == newS[newS.count - 1 - suffix] {
            suffix += 1
        }

        let deleteCount = oldS.count - prefix - suffix
        let inserted = String(String.UnicodeScalarView(newS[prefix..<(newS.count - suffix)]))
        try? doc.spliceText(obj: textObj, start: UInt64(prefix), delete: Int64(deleteCount), value: inserted)
    }

    /// Merge an incoming delta (another device's `encodeChangesSince`). Returns
    /// true if the merge changed our text, so the caller can skip a no-op refresh.
    @discardableResult
    func applyDelta(_ data: Data) -> Bool {
        let before = markdown
        try? doc.applyEncodedChanges(encoded: data)
        return markdown != before
    }

    /// The delta of everything since `heads` — what to broadcast after a local edit.
    func delta(since heads: Set<ChangeHash>) -> Data? {
        guard let d = try? doc.encodeChangesSince(heads: heads), !d.isEmpty else { return nil }
        return d
    }

    /// A full compacted snapshot for seeding new joiners.
    func snapshot() -> Data { doc.save() }
}
#endif
