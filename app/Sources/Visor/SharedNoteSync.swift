#if canImport(FirebaseFirestore) && canImport(FirebaseDatabase) && canImport(Automerge)
import Automerge
import FirebaseDatabase
import FirebaseFirestore
import Foundation

extension NoteSyncFactory {
    static func makeBackend() -> NoteSyncing? { SharedNoteSync() }
}

/// Live sync for one shared note at a time, using a two-tier transport.
///
/// **Live ops → Realtime Database.** Per-keystroke Automerge deltas stream
/// through RTDB at `beams/{id}/ops` (each entry: `{c: clientId, d: base64 delta}`).
/// RTDB is metered by bandwidth, not by a per-write daily cap like Firestore, so
/// high-frequency tiny deltas are cheap — that's what makes near-per-character
/// updates affordable on the free tier. Every device merges deltas into its own
/// `CRDTNote`; there is no server-side merge.
///
/// **Durable snapshot → Firestore.** `sharedNotes/{id}` holds a compacted
/// Automerge `snapshot`, refreshed only occasionally (every `snapshotEveryPushes`
/// pushes and on detach). New joiners bootstrap from it, then replay the recent
/// RTDB ops on top. Firestore writes are thus rare (just snapshots), staying well
/// under the 20K/day free cap.
///
/// **Why a CRDT and not last-write-wins.** Two people typing at once produce
/// concurrent deltas; Automerge merges them per-character instead of one save
/// clobbering the other.
///
/// **Identity model (capability links).** No Firebase Auth (see `FirebaseBootstrap`
/// for why). The beam link carries an unguessable `id`+`token`; possessing the
/// link is the capability. Rules allow access by id but deny enumeration.
///
/// One engine instance is attached to at most one note; switching notes calls
/// `detach()` then re-binds. All callbacks land on the main thread, which is also
/// where `NotesStore` lives, so no extra synchronization is needed.
final class SharedNoteSync: NoteSyncing {
    var onRemoteMarkdown: ((String) -> Void)?
    var onPresenceCount: ((Int) -> Void)?

    private let db = Firestore.firestore()
    private let rtdb = Database.database(url: SharedNoteSync.rtdbURL)
    /// Distinguishes our own ops coming back through the listener (already applied
    /// locally) from genuinely remote ones.
    private let clientId = UUID().uuidString

    private var ref: BeamRef?
    private var crdt: CRDTNote?
    /// Version vector at our last push, so the next delta carries only new edits.
    private var lastPushedHeads: Set<ChangeHash> = []
    /// RTDB op keys we've already merged, to stay idempotent across re-deliveries.
    private var appliedOpKeys: Set<String> = []

    private var metaListener: ListenerRegistration?
    private var opsRef: DatabaseReference?
    private var opsHandle: DatabaseHandle?
    private var presenceRef: DatabaseReference?      // our own presence node
    private var presenceListRef: DatabaseReference?  // the note's presence list
    private var presenceHandle: DatabaseHandle?
    private var pushTask: DispatchWorkItem?
    /// Local pushes since we last rolled up the Firestore snapshot. Live edits ride
    /// on RTDB ops, so the snapshot only needs occasional refresh — keeping
    /// Firestore writes rare. New joiners replay at most this many recent ops.
    private var pushesSinceSnapshot = 0

    /// Default RTDB instance for this Firebase project. Hardcoded because the
    /// bundled GoogleService-Info.plist predates the database and lacks its URL;
    /// it isn't a secret (it ships in the app regardless).
    private static let rtdbURL = "https://kitalabs-default-rtdb.firebaseio.com"
    private static let collection = "sharedNotes"
    /// Small debounce so a burst of keystrokes coalesces into one op (imperceptible
    /// ~80ms) without firing a separate RTDB write per character.
    private static let pushDebounce = 0.08
    /// Roll up the Firestore snapshot at most once per this many local pushes.
    private static let snapshotEveryPushes = 40
    /// Cap how many recent ops a fresh listener replays (the rest are folded into
    /// the snapshot it bootstrapped from).
    private static let opReplayLimit: UInt = 500

    // MARK: - Local CRDT snapshot cache

    /// Per-note Automerge snapshots, so reopening a shared note is instant and
    /// offline edits survive a relaunch. Critically, this lets us re-attach by
    /// loading a snapshot that *shares history* with the remote doc — never by
    /// re-seeding from local markdown, which would duplicate every character on
    /// the next merge (two independent insert histories of "the same" text).
    private var crdtDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Visor/.crdt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func snapshotURL(_ id: String) -> URL {
        crdtDir.appendingPathComponent("\(id).automerge")
    }

    private func loadLocalSnapshot(_ id: String) -> CRDTNote? {
        guard let data = try? Data(contentsOf: snapshotURL(id)) else { return nil }
        return try? CRDTNote(snapshot: data)
    }

    private func persistLocalSnapshot() {
        guard let ref, let crdt else { return }
        try? crdt.snapshot().write(to: snapshotURL(ref.id), options: .atomic)
    }

    // MARK: - NoteSyncing

    func share(markdown: String, completion: @escaping (BeamRef?) -> Void) {
        guard FirebaseBootstrap.configured else { completion(nil); return }
        let docRef = db.collection(Self.collection).document()
        let ref = BeamRef(id: docRef.documentID, token: UUID().uuidString)
        let note = CRDTNote(markdown: markdown)
        let payload: [String: Any] = [
            "token": ref.token,
            "snapshot": note.snapshot(),
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        docRef.setData(payload) { [weak self] error in
            guard let self else { completion(nil); return }
            if let error {
                NSLog("[Visor] share failed: \(error.localizedDescription)")
                completion(nil)
                return
            }
            self.crdt = note
            self.bind(ref: ref)
            completion(ref)
        }
    }

    func join(ref: BeamRef, completion: @escaping (String?) -> Void) {
        guard FirebaseBootstrap.configured else { completion(nil); return }
        // Capability model: knowing the id (in the link) is what grants access —
        // the rules allow `get` by id, so we just read the note's snapshot. No
        // membership write, no auth.
        db.collection(Self.collection).document(ref.id).getDocument { [weak self] snapshot, error in
            guard let self else { completion(nil); return }
            guard let data = snapshot?.data(),
                  let snap = data["snapshot"] as? Data,
                  let note = try? CRDTNote(snapshot: snap) else {
                if let error { NSLog("[Visor] join failed: \(error.localizedDescription)") }
                completion(nil)
                return
            }
            self.crdt = note
            self.bind(ref: ref)
            completion(note.markdown)
        }
    }

    func attach(ref: BeamRef, localMarkdown: String) {
        // Re-attach to an already-joined note. Seed only from a local snapshot
        // that shares history with the remote doc; if we somehow have none, leave
        // the CRDT nil and let the metadata listener seed it from the remote
        // snapshot (localMarkdown is shown meanwhile by the caller).
        crdt = loadLocalSnapshot(ref.id)
        bind(ref: ref)
    }

    func pushLocal(markdown: String) {
        guard ref != nil else { return }
        pushTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.flushPush(markdown) }
        pushTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushDebounce, execute: task)
    }

    func detach() {
        // Flush a pending debounced push synchronously so the final edit isn't
        // lost (and is included in the rolled-up snapshot below). Re-running an
        // already-fired push is a no-op — its delta-since-heads is empty.
        if let pending = pushTask { pending.perform() }
        pushTask?.cancel(); pushTask = nil
        detachListeners()
        rollUpSnapshot()        // leave the note fully compacted for the next joiner
        persistLocalSnapshot()
        crdt = nil
        ref = nil
        lastPushedHeads = []
        appliedOpKeys = []
        pushesSinceSnapshot = 0
    }

    // MARK: - Internals

    /// Wire up listeners for `ref` and record our starting version vector.
    private func bind(ref: BeamRef) {
        detachListeners()
        self.ref = ref
        appliedOpKeys = []
        lastPushedHeads = crdt?.heads() ?? []
        persistLocalSnapshot()

        let docRef = db.collection(Self.collection).document(ref.id)

        // Firestore snapshot: seeds the CRDT the first time when we have no local
        // copy yet (e.g. a join without a prior on-disk snapshot). Once seeded, we
        // start the live ops observer (so we don't drop ops that arrive pre-seed).
        metaListener = docRef.addSnapshotListener { [weak self] snapshot, _ in
            guard let self, self.crdt == nil,
                  let snap = snapshot?.data()?["snapshot"] as? Data,
                  let note = try? CRDTNote(snapshot: snap) else { return }
            self.crdt = note
            self.lastPushedHeads = note.heads()
            self.persistLocalSnapshot()
            self.onRemoteMarkdown?(note.markdown)
            self.startOpsObserver()
        }

        // If we already hold the CRDT (share/join/attach seeded it), start the live
        // ops stream immediately.
        if crdt != nil { startOpsObserver() }

        startPresence()
    }

    /// Announce our presence on the note and report the live viewer count. Uses
    /// RTDB `onDisconnect` so a crash/quit auto-removes us — no stale "ghosts".
    private func startPresence() {
        guard presenceHandle == nil, let ref = self.ref else { return }
        let base = rtdb.reference().child("beams").child(ref.id).child("presence")
        let mine = base.child(clientId)
        presenceRef = mine
        presenceListRef = base
        mine.onDisconnectRemoveValue()
        mine.setValue(ServerValue.timestamp())
        presenceHandle = base.observe(.value) { [weak self] snap in
            self?.onPresenceCount?(Int(snap.childrenCount))
        }
    }

    /// Subscribe to the RTDB live op stream and merge each remote delta as it
    /// arrives. Idempotent: re-delivered ops and the initial replay are filtered by
    /// key, and applying an already-known Automerge change is a no-op anyway.
    private func startOpsObserver() {
        guard opsHandle == nil, let ref = self.ref else { return }
        let opsRef = rtdb.reference().child("beams").child(ref.id).child("ops")
        self.opsRef = opsRef
        opsHandle = opsRef.queryLimited(toLast: Self.opReplayLimit).observe(.childAdded) { [weak self] snap in
            guard let self else { return }
            guard !self.appliedOpKeys.contains(snap.key) else { return }
            self.appliedOpKeys.insert(snap.key)
            guard let v = snap.value as? [String: Any],
                  (v["c"] as? String) != self.clientId,                 // skip our own echo
                  let b64 = v["d"] as? String,
                  let delta = Data(base64Encoded: b64),
                  let crdt = self.crdt else { return }
            if crdt.applyDelta(delta) {
                self.lastPushedHeads = crdt.heads()
                self.persistLocalSnapshot()
                self.onRemoteMarkdown?(crdt.markdown)
            }
        }
    }

    private func detachListeners() {
        metaListener?.remove(); metaListener = nil
        if let opsRef, let opsHandle { opsRef.removeObserver(withHandle: opsHandle) }
        opsRef = nil; opsHandle = nil
        // Presence: stop announcing ourselves and stop counting.
        if let presenceRef {
            presenceRef.cancelDisconnectOperations()
            presenceRef.removeValue()
        }
        if let presenceListRef, let presenceHandle {
            presenceListRef.removeObserver(withHandle: presenceHandle)
        }
        presenceRef = nil; presenceListRef = nil; presenceHandle = nil
        onPresenceCount?(0)
    }

    /// Apply a local edit to the CRDT and broadcast the delta.
    private func flushPush(_ markdown: String) {
        guard let ref, let crdt else { return }
        crdt.setMarkdown(markdown)
        guard let delta = crdt.delta(since: lastPushedHeads) else { return }
        lastPushedHeads = crdt.heads()
        persistLocalSnapshot()

        // Live op → RTDB. This is what drives every other participant's update;
        // RTDB is bandwidth-metered, so streaming small deltas is cheap. `c` tags
        // our own writes so the observer skips the echo; `d` is the base64 delta
        // (RTDB has no native bytes type). `t` is a server timestamp for ordering.
        let opsRef = self.opsRef ?? rtdb.reference().child("beams").child(ref.id).child("ops")
        opsRef.childByAutoId().setValue([
            "c": clientId,
            "d": delta.base64EncodedString(),
            "t": ServerValue.timestamp(),
        ])

        // Refresh the Firestore snapshot only occasionally — it just bootstraps new
        // joiners (live edits ride on RTDB), so this keeps Firestore writes rare.
        pushesSinceSnapshot += 1
        if pushesSinceSnapshot >= Self.snapshotEveryPushes { rollUpSnapshot() }
    }

    /// Write the compacted snapshot to the note doc (the only thing that lets a
    /// new joiner skip replaying the change log). Resets the push counter.
    private func rollUpSnapshot() {
        guard let ref, let crdt, pushesSinceSnapshot > 0 else { return }
        pushesSinceSnapshot = 0
        db.collection(Self.collection).document(ref.id)
            .updateData(["snapshot": crdt.snapshot(), "updatedAt": FieldValue.serverTimestamp()])
    }
}
#endif
