#if canImport(Automerge)
import Foundation
import Automerge

extension NoteSyncFactory {
    /// Live sharing needs somewhere to sync to. There is no configuration file
    /// and no SDK to initialise any more — just a database URL — so this is
    /// always available when the CRDT is linked.
    static func makeBackend() -> NoteSyncing? { SharedNoteSync() }
}

/// Live sync for one shared note at a time, over the database's HTTP API.
///
/// **Live ops.** Per-keystroke Automerge deltas stream through
/// `beams/{id}/ops` (each entry: `{c: clientId, d: base64 delta}`). Every device
/// merges deltas into its own `CRDTNote`; there is no server-side merge.
/// Updates arrive as server-sent events on a held-open HTTPS response, which is
/// what a database SDK's socket was doing underneath anyway.
///
/// **Durable snapshot.** `beams/{id}/snapshot` holds a compacted Automerge
/// document, refreshed occasionally and on detach. New joiners bootstrap from
/// it and replay the recent ops on top. This lived in Firestore before — a
/// second database, and a second SDK, for one rarely-written value.
///
/// **Why a CRDT and not last-write-wins.** Two people typing at once produce
/// concurrent deltas; Automerge merges them per-character instead of one save
/// clobbering the other. This is the one piece that has to be in the binary:
/// it is the merge itself, and it runs on every keystroke.
///
/// **Identity model (capability links).** No auth. The beam link carries an
/// unguessable `id`; possessing the link is the capability, and the database
/// rules allow access by id while denying enumeration.
///
/// One engine instance is attached to at most one note; switching notes calls
/// `detach()` then re-binds. All callbacks land on the main thread, which is
/// also where `NotesStore` lives, so no extra synchronization is needed.
final class SharedNoteSync: NoteSyncing {
    var onRemoteMarkdown: ((String) -> Void)?
    var onPresenceCount: ((Int) -> Void)?

    private let db = RealtimeDB(base: URL(string: SharedNoteSync.databaseURL)!)
    /// Distinguishes our own ops coming back through the stream (already applied
    /// locally) from genuinely remote ones.
    private let clientId = UUID().uuidString

    private var ref: BeamRef?
    private var crdt: CRDTNote?
    /// Version vector at our last push, so the next delta carries only new edits.
    private var lastPushedHeads: Set<ChangeHash> = []
    /// Op keys we've already merged, to stay idempotent across re-deliveries.
    private var appliedOpKeys: Set<String> = []

    private var opsTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pushTask: DispatchWorkItem?
    /// Local pushes since the last snapshot roll-up.
    private var pushesSinceSnapshot = 0

    /// Not a secret: it shipped inside the app either way, and access is
    /// governed by the unguessable note id rather than by hiding this.
    private static let databaseURL = "https://kitalabs-default-rtdb.firebaseio.com"
    /// Small debounce so a burst of keystrokes coalesces into one op
    /// (imperceptible ~80ms) without firing a separate write per character.
    private static let pushDebounce = 0.08
    /// Roll up the snapshot at most once per this many local pushes.
    private static let snapshotEveryPushes = 40
    /// Cap how many recent ops a fresh stream replays (the rest are folded into
    /// the snapshot it bootstrapped from).
    private static let opReplayLimit = 500
    /// How often we say we're still here, and how long that claim is believed.
    ///
    /// The SDK removed a presence node the instant a socket dropped. Without
    /// that, someone who crashes is counted until their last heartbeat goes
    /// stale — so the window is short enough that a ghost is brief and long
    /// enough that a slow network isn't mistaken for a departure.
    private static let heartbeat: TimeInterval = 20
    private static let presenceTTL: TimeInterval = 60

    /// URL-safe lowercase slug of a note title, for a readable doc id. Falls back
    /// to "note" when the title has no usable characters.
    private static func slug(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let dashes = CharacterSet(charactersIn: "-")
        let capped = String(out.prefix(30)).trimmingCharacters(in: dashes)
        return capped.isEmpty ? "note" : capped
    }

    /// Short random suffix (8 lowercase alphanumerics, ~41 bits) — the unguessable
    /// part of the capability id.
    private static func randomSuffix() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

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

    // MARK: - Paths

    private func opsPath(_ id: String) -> String { "beams/\(id)/ops" }
    private func snapshotPath(_ id: String) -> String { "beams/\(id)/snapshot" }
    private func presencePath(_ id: String) -> String { "beams/\(id)/presence" }

    // MARK: - NoteSyncing

    func share(markdown: String, nameHint: String, completion: @escaping (BeamRef?) -> Void) {
        // Readable-but-unguessable id: "note-name-slug" + short random suffix.
        let id = Self.slug(nameHint) + "-" + Self.randomSuffix()
        let ref = BeamRef(id: id)
        let note = CRDTNote(markdown: markdown)
        Task { @MainActor in
            let wrote = await db.put(snapshotPath(id), [
                "d": note.snapshot().base64EncodedString(),
                "updatedAt": RealtimeDB.serverTimestamp,
            ])
            guard wrote else {
                NSLog("[Visor] share failed: could not write the note")
                completion(nil)
                return
            }
            self.crdt = note
            self.bind(ref: ref)
            completion(ref)
        }
    }

    func join(ref: BeamRef, completion: @escaping (String?) -> Void) {
        // Capability model: knowing the id (in the link) is what grants access,
        // so this is a plain read. No membership write, no auth.
        Task { @MainActor in
            guard let object = await db.get(snapshotPath(ref.id)) as? [String: Any],
                  let b64 = object["d"] as? String,
                  let data = Data(base64Encoded: b64),
                  let note = try? CRDTNote(snapshot: data) else {
                NSLog("[Visor] join failed: no note at that link")
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
        // that shares history with the remote doc; with none, leave the CRDT nil
        // and let the remote snapshot seed it (the caller shows localMarkdown
        // meanwhile).
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
        // lost. Re-running an already-fired push is a no-op — its delta-since-
        // heads is empty.
        if let pending = pushTask { pending.perform() }
        pushTask?.cancel(); pushTask = nil
        let id = ref?.id
        detachListeners()
        rollUpSnapshot()        // leave the note compacted for the next joiner
        persistLocalSnapshot()
        if let id {
            let client = clientId
            Task { await db.delete("beams/\(id)/presence/\(client)") }
        }
        crdt = nil
        ref = nil
        lastPushedHeads = []
        appliedOpKeys = []
        pushesSinceSnapshot = 0
    }

    // MARK: - Internals

    private func bind(ref: BeamRef) {
        detachListeners()
        self.ref = ref
        appliedOpKeys = []
        lastPushedHeads = crdt?.heads() ?? []
        persistLocalSnapshot()

        if crdt == nil {
            // Nothing local to start from: fetch the snapshot, then start the op
            // stream, so no op arrives before there's a document to merge it in.
            Task { @MainActor in
                if let object = await db.get(snapshotPath(ref.id)) as? [String: Any],
                   let b64 = object["d"] as? String,
                   let data = Data(base64Encoded: b64),
                   let note = try? CRDTNote(snapshot: data) {
                    self.crdt = note
                    self.lastPushedHeads = note.heads()
                    self.persistLocalSnapshot()
                    self.onRemoteMarkdown?(note.markdown)
                }
                self.startOps(ref)
            }
        } else {
            startOps(ref)
        }
        startPresence(ref)
    }

    /// Merge every remote delta as it arrives.
    ///
    /// Idempotent: re-delivered ops and the initial replay are filtered by key,
    /// and applying an already-known Automerge change is a no-op anyway.
    private func startOps(_ ref: BeamRef) {
        guard opsTask == nil else { return }
        let stream = db.stream(opsPath(ref.id), query: [
            URLQueryItem(name: "orderBy", value: "\"$key\""),
            URLQueryItem(name: "limitToLast", value: String(Self.opReplayLimit)),
        ])
        opsTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                // The opening event is the whole node; everything after is one
                // child. Both shapes reduce to a list of (key, op).
                if event.path == "/" {
                    let all = (event.value as? [String: Any]) ?? [:]
                    for (key, value) in all.sorted(by: { $0.key < $1.key }) {
                        self.apply(key: key, op: value)
                    }
                } else {
                    self.apply(key: String(event.path.dropFirst()), op: event.value)
                }
            }
        }
    }

    private func apply(key: String, op: Any?) {
        guard !key.isEmpty, !appliedOpKeys.contains(key) else { return }
        appliedOpKeys.insert(key)
        guard let value = op as? [String: Any],
              (value["c"] as? String) != clientId,          // skip our own echo
              let b64 = value["d"] as? String,
              let delta = Data(base64Encoded: b64),
              let crdt else { return }
        if crdt.applyDelta(delta) {
            lastPushedHeads = crdt.heads()
            persistLocalSnapshot()
            onRemoteMarkdown?(crdt.markdown)
        }
    }

    /// Say we're here, keep saying it, and count everyone else doing the same.
    private func startPresence(_ ref: BeamRef) {
        guard presenceTask == nil else { return }
        let path = presencePath(ref.id)
        let mine = "\(path)/\(clientId)"

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.db.put(mine, ["t": Date().timeIntervalSince1970 * 1000])
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeat * 1_000_000_000))
            }
        }

        let stream = db.stream(path)
        presenceTask = Task { @MainActor [weak self] in
            var seen: [String: Double] = [:]
            for await event in stream {
                guard let self else { return }
                if event.path == "/" {
                    seen = [:]
                    for (key, value) in (event.value as? [String: Any]) ?? [:] {
                        seen[key] = ((value as? [String: Any])?["t"] as? Double) ?? 0
                    }
                } else {
                    let key = String(event.path.dropFirst()).split(separator: "/").first.map(String.init) ?? ""
                    guard !key.isEmpty else { continue }
                    if let value = event.value {
                        seen[key] = ((value as? [String: Any])?["t"] as? Double) ?? 0
                    } else {
                        seen.removeValue(forKey: key)
                    }
                }
                // Anyone whose last heartbeat has gone stale is treated as gone.
                // Without the SDK's onDisconnect this is what stops a crashed
                // client being counted forever.
                let cutoff = (Date().timeIntervalSince1970 - Self.presenceTTL) * 1000
                self.onPresenceCount?(seen.values.filter { $0 >= cutoff }.count)
            }
        }
    }

    private func detachListeners() {
        opsTask?.cancel(); opsTask = nil
        presenceTask?.cancel(); presenceTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        onPresenceCount?(0)
    }

    /// Apply a local edit to the CRDT and broadcast the delta.
    private func flushPush(_ markdown: String) {
        guard let ref, let crdt else { return }
        crdt.setMarkdown(markdown)
        guard let delta = crdt.delta(since: lastPushedHeads) else { return }
        lastPushedHeads = crdt.heads()
        persistLocalSnapshot()

        // `c` tags our own writes so the stream skips the echo; `d` is the
        // base64 delta (the database has no native bytes type); `t` orders them.
        let payload: [String: Any] = [
            "c": clientId,
            "d": delta.base64EncodedString(),
            "t": RealtimeDB.serverTimestamp,
        ]
        let path = opsPath(ref.id)
        Task { await db.post(path, payload) }

        pushesSinceSnapshot += 1
        if pushesSinceSnapshot >= Self.snapshotEveryPushes { rollUpSnapshot() }
    }

    /// Write the compacted snapshot, the only thing that lets a new joiner skip
    /// replaying the change log.
    private func rollUpSnapshot() {
        guard let ref, let crdt, pushesSinceSnapshot > 0 else { return }
        pushesSinceSnapshot = 0
        let payload: [String: Any] = [
            "d": crdt.snapshot().base64EncodedString(),
            "updatedAt": RealtimeDB.serverTimestamp,
        ]
        let path = snapshotPath(ref.id)
        Task { await db.put(path, payload) }
    }
}
#endif
