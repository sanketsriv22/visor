# Live note sharing (capability links + CRDT)

Beaming a note used to send a one-time copy: the markdown rode inside the link's
URL fragment and the recipient got a frozen snapshot. Now a beam creates a
**live shared note** — both sides edit it and changes sync per-character in real
time.

## How it works

- **No Firebase Auth.** Auth on macOS needs to write the session to the
  data-protection keychain, which requires a Team-ID-prefixed entitlement only
  available with Apple-managed code signing. This app ships ad-hoc signed (no
  Developer Program), so we skip auth entirely — see `FirebaseBootstrap`.
- **Capability model.** A shared note is reached only via its unguessable id +
  token, carried in the beam link (`…/beam/#s/<id>/<token>`). Possessing the link
  is the capability. Rules allow access *by id* but deny enumeration.
- **Two-tier transport:**
  - **Live ops → Realtime Database** at `beams/{id}/ops`. Each keystroke-batch is
    an Automerge delta (`{c: clientId, d: base64}`). RTDB is metered by bandwidth,
    not a per-write daily cap like Firestore, so per-character streaming is cheap.
  - **Durable snapshot → Firestore** `sharedNotes/{id}` holds a compacted
    Automerge `snapshot`, refreshed only every ~40 pushes and on detach. New
    joiners bootstrap from it, then replay recent RTDB ops. Firestore writes stay
    rare (well under the 20K/day free cap).
- **Merge: Automerge (CRDT).** The whole markdown is one character-addressable
  `Text`; concurrent edits merge per-character instead of clobbering.
- **Presence** at `beams/{id}/presence/{clientId}` with RTDB `onDisconnect`
  cleanup — drives the live "N viewing" badge.

Code map:

| File | Role |
|------|------|
| `FirebaseBootstrap.swift` | `FirebaseApp.configure()` only — no auth |
| `CRDTNote.swift` | Automerge wrapper; markdown ↔ `Text` with minimal-diff splices |
| `SharedNoteSync.swift` | RTDB op stream + presence + Firestore snapshot; one note at a time |
| `NoteSync.swift` | `NoteSyncing` protocol + `BeamRef`; the seam `NotesStore` talks to |
| `BeamLink.swift` | Encodes/decodes `#s/<id>/<token>` (still decodes legacy copy links) |
| `NotesStore.swift` | `shareNote`, `joinShared` (idempotent), live push on edit, apply-remote-when-clean, share/presence state |

The whole stack is behind `#if canImport(FirebaseFirestore) && canImport(FirebaseDatabase) && canImport(Automerge)`
plus a plist check, so the app builds and runs without it — sharing just falls
back to the legacy offline copy.

## One-time setup

1. **Firebase project** with an Apple app registered as bundle id
   `com.kitalabs.visor` (no Apple Developer membership needed — it's just a
   string). Download `GoogleService-Info.plist`.
2. **Drop the plist at the repo root** (`visor/GoogleService-Info.plist`,
   gitignored). `make-app.sh` bundles it. Override with `GOOGLE_SERVICE_PLIST`.
3. **Create Firestore** (Standard edition, production mode).
4. **Create the Realtime Database** (default instance). The URL is hardcoded in
   `SharedNoteSync.rtdbURL` because the bundled plist predates the database.
5. **Deploy the rules:** `firebase deploy --only firestore:rules,database --project kitalabs`
   (rules live in `firestore.rules` and `database.rules.json`).

Anonymous auth is **not** used and does not need enabling.

## Security model & limitations

Capability sharing is the same trust model as "anyone with the link" in Google
Docs / Figma. Known, accepted tradeoffs:

- **The link is the password.** Anyone who obtains it can read *and edit*; there's
  no per-user permission or revocation.
- **Notes are plaintext at rest** in Firebase (not end-to-end encrypted).
- **No per-user identity.** Presence shows who's *currently* viewing (anonymous
  count), not a durable access list. Real per-user read/write permissions would
  require identity — i.e. Firebase Auth + paid signing, or a backend like Supabase.
- **No op-log pruning yet.** RTDB ops accumulate under `beams/{id}/ops`; a fresh
  listener replays the last 500. A busy long-lived note should periodically clear
  ops already folded into the Firestore snapshot.
- **Idempotent joins are per-device** (id→note mapping in `UserDefaults`).

## Known follow-ups

- Simultaneous-typing UX: remote edits currently apply only when you're *not*
  typing (so your cursor isn't disturbed). True concurrent typing needs applying
  remote deltas into the editor while preserving the local cursor.
- Op-log pruning (above).
- If real accounts/permissions become core: migrate identity to Supabase (free)
  or add Firebase Auth (needs paid Developer ID signing).
