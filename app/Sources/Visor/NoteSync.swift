import Foundation

/// A reference to a shared note: the Firestore document id plus a capability
/// token. The token is a random secret that gates membership — a beam link
/// carries both, and joining proves you hold the token before the rules add you
/// to the note's member list. Knowing an id alone is not enough to read a note.
struct BeamRef: Equatable {
    /// The shared note's Firestore document id. It doubles as the capability —
    /// knowing it (via the beam link) is what grants access — so it must stay
    /// unguessable. We use `note-name-slug` + a short random suffix for a readable
    /// yet hard-to-guess id.
    let id: String
}

/// The seam between `NotesStore` and the real-time sync backend. The store never
/// imports the sync stack directly — it talks to this protocol — so the
/// app compiles and runs even when the sharing stack isn't available (no SDK
/// resolved yet, or no `GoogleService-Info.plist` bundled). In that case
/// `NoteSyncFactory.make()` returns nil and every share action degrades to the
/// old offline copy.
///
/// All methods are called on the main thread and all callbacks are delivered on
/// the main thread.
protocol NoteSyncing: AnyObject {
    /// Called when a remote edit has been merged and the note's markdown changed.
    /// The store decides whether to surface it (it applies remote text when the
    /// user isn't mid-edit, mirroring `reloadFromDiskIfClean`).
    var onRemoteMarkdown: ((String) -> Void)? { get set }

    /// Called with the number of clients currently viewing the attached note
    /// (including this one). 0 when not attached to a shared note.
    var onPresenceCount: ((Int) -> Void)? { get set }

    /// Promote the current note into a brand-new shared note. `markdown` seeds
    /// the CRDT; `nameHint` is the note's title, used to build a readable doc id.
    /// On success the completion carries the `BeamRef` to embed in a link; on
    /// failure it carries nil and the caller should fall back to an offline copy.
    /// Leaves the engine attached to the new shared note.
    func share(markdown: String, nameHint: String, completion: @escaping (BeamRef?) -> Void)

    /// Join an existing shared note. The completion carries the note's current
    /// markdown (the seed to show locally), or nil if the join failed (bad token,
    /// offline, deleted). Leaves the engine attached on success.
    func join(ref: BeamRef, completion: @escaping (String?) -> Void)

    /// Re-attach to an already-joined shared note (e.g. switching back to it).
    /// `localMarkdown` is the on-disk copy used to seed the CRDT before the first
    /// snapshot arrives, so the note shows instantly.
    func attach(ref: BeamRef, localMarkdown: String)

    /// Feed a local edit into the CRDT and push the resulting delta. Debounced
    /// internally; safe to call on every keystroke-batch.
    func pushLocal(markdown: String)

    /// Stop listening and drop the in-memory CRDT (e.g. switching to another
    /// note). Does not delete anything remote.
    func detach()
}

/// Builds the live sync engine when the backend is available, else nil.
///
/// The concrete implementation lives in `SharedNoteSync` behind a `canImport`
/// guard, and `makeBackend()` is provided there. When the Automerge
/// products aren't linked, the fallback below wins and sharing stays offline.
enum NoteSyncFactory {
    static func make() -> NoteSyncing? { makeBackend() }
}

#if !canImport(Automerge)
extension NoteSyncFactory {
    /// No sharing backend linked — sharing degrades to the offline copy path.
    static func makeBackend() -> NoteSyncing? { nil }
}
#endif
