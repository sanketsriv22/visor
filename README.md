# Visor

A native AI tool that lives inside your MacBook's camera notch — invisible
until you click it (or press ⌘⇧K), at which point it slides down beneath the
notch. It has two faces:

- **Notes** — a sticky note of plain-markdown tasks, on disk, readable and
  writable by agents.
- **Chat** — a composer wired to any model OpenRouter offers, with agents you
  name yourself, on-device memory of past conversations, and export.

Switch between them with the control in the notch's left shoulder, or ⌘1 / ⌘2.
The card grows sideways when you move to chat; the notch stays the notch.

Everything is local files. Agents reach both faces through Visor's MCP server —
they can survey what you haven't done, read what you've been thinking about,
and post back into a chat so their answer lands in the notch.

```
~/Documents/Visor/*.md          notes (plain markdown)
~/StickyNotes/chats/*.json      conversations, one file each
        ▲            ▲
   notch app     MCP server ──► agents (Claude Code, Codex, Cursor, Devin, …)
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/sanketsriv22/visor/main/install.sh | bash
```

Downloads the prebuilt `Visor.app` from the latest [release](https://github.com/sanketsriv22/visor/releases)
and installs it to `/Applications` — no compiler or toolchain needed (Apple
Silicon). To build from source instead (needs git + a Swift toolchain):

```sh
VISOR_FROM_SOURCE=1 curl -fsSL https://raw.githubusercontent.com/sanketsriv22/visor/main/install.sh | bash
# or, from a local checkout:
./scripts/make-app.sh        # builds Visor.app and installs it to /Applications
```

## The app

- Click the notch → the note slides down under it. Click the notch again
  (or press Esc) → it slides away. Until then it stays put.
- Tasks are checkboxes: type in the **Add a task…** field (Enter for the next),
  click the circle to complete, hover a row to delete. On disk a task is just
  `- [ ] …` / `- [x] …`, so agents read and write the same file.
- A **menu-bar icon** (the only visible chrome) shows the version + what's new,
  toggles the note, self-updates, and quits. No Dock icon; nothing else visible
  while collapsed.
- The dropdown shows the running **version**, a **What's New** submenu (this
  version's changelog), and whether you're **up to date** vs an update being
  available. **Update Visor** downloads the latest release, swaps it into
  `/Applications`, and relaunches — no terminal needed.

### Versioning

The version lives in [`VERSION`](VERSION); changes are logged in
[`CHANGELOG.md`](CHANGELOG.md). Every push to `main` rebuilds and publishes a
release tagged from `VERSION` (notes = that version's changelog section) via
GitHub Actions, so the Update button always serves current `main`. To cut a new
version, bump `VERSION` and add a `CHANGELOG.md` entry. Publish from your
machine with `./scripts/release.sh`.
- No notch (external display)? A 200pt-wide invisible strip at the top-center
  of the screen does the same job.
- The note picks up external edits (MCP server, Devin, git) live, so writes
  from those don't get clobbered.
- `--expanded` starts with the note open; `--probe` prints detected notch
  geometry and exits.

To launch at login, add `/Applications/Visor.app` in System Settings → General →
Login Items.

### Storage

Notes live at `~/StickyNotes/sticky.md` (override with the
`STICKY_NOTES_FILE` env var — the app and MCP server both honor it). The app
saves ~0.6s after you stop typing and when the note collapses, and reloads
external edits whenever it opens. Last writer wins; don't edit in two places
at the exact same moment.

## Chat

Press ⌘⇧K, hit ⌘2, and type. Replies stream into the notch.

**Agents.** Name as many as you like in Settings → Agents. Each one picks its
own model from whatever your OpenRouter key can reach (the list is fetched
live, never hard-coded), and can carry a persona that's prepended to every
conversation. One OpenRouter key is shared by all of them, stored in your
macOS Keychain — you paste it once, no matter how many agents you name.

A **CLI agent** is still a first-class option: name it, point it at `claude`,
`codex`, `devin`, whatever, and sends open a Terminal or run in the background
as before. The ✈ button on a task sends it to whichever agent is default — and
if that's a chat agent, it answers in the notch instead of shelling out.

**Memory.** Visor embeds every turn on-device with `NLEmbedding`, so an agent
can recall what you discussed weeks ago. Nothing leaves the machine to do it
and there's no embedding bill. Each reply gets the recent turns verbatim plus
the most relevant excerpts from *other* conversations, which is what keeps a
long history from growing the cost of every message. Deleting a chat forgets
it. If macOS has no embedding model for your locale, chats still work — just
without recall.

**Export.** Copy any chat as markdown, or export it to `~/StickyNotes/exports/`
as markdown or JSON.

## Settings

⌘, opens a real window, not a dropdown — agents have names, models, personas
and keys now, and there's memory and MCP wiring on top of that.

| Pane | What's there |
| --- | --- |
| Agents | Create, rename, delete. Model picker, persona, per-agent keys, the shared OpenRouter key. |
| Workspace | Terminal vs background for CLI agents, the project folder they run in, shortcuts. |
| MCP | Ready-to-paste setup commands for Claude Code, Codex, Cursor and Devin. |
| Memory | What's stored, where it lives, and a way to rebuild the index. |

## The MCP server

```sh
cd mcp-server
npm install && npm run build
```

Note tools: `read_sticky`, `list_tasks` (with `firstSeen`/`ageHours` per task
and an `older_than_hours` filter), `list_notes`, `add_task`, `add_note`,
`complete_task`. First-seen timestamps are kept in `.meta.json`, maintained
automatically — the note file itself stays clean.

Chat tools: `list_chats`, `read_chat`, `search_chats`, and `post_to_chat` —
which writes a message into a conversation so it shows up in the notch. That's
the "communicate with it" half: an agent can finish a job and tell you so
where you'll actually see it.

Reads go to the chat files themselves rather than the index cache, so an agent
never sees a stale listing.

Hook it up to Claude Code:

```sh
claude mcp add visor -- node ~/repos/visor/mcp-server/dist/index.js
```

Now "check my stickies" works in any session, and agents can add tasks too.

## Connecting Devin

Uses the **local Devin CLI** (`docs.devin.ai/cli`), which runs on your machine
and reads `~/StickyNotes/sticky.md` straight off disk — so there's no API key,
no private repo, and no git sync to maintain. One-time setup:

```sh
curl -fsSL https://cli.devin.ai/install.sh | bash   # if not already installed
devin auth login                                    # stores creds in ~/.local/share/devin
```

### The proactive part

MCP is pull-only — something has to tell Devin to look. `scripts/devin-check.sh`
does the nudging:

1. asks the MCP server for open tasks older than `VISOR_HOURS` (default 24) —
   `node mcp-server/dist/index.js --stale 24` if you want it by hand;
2. fires a macOS notification listing them (instant, reliable);
3. runs `devin -p` with that list so Devin can send a richer Slack message
   (if you've connected Slack via `devin mcp`) and/or start the work.

By default Devin runs read-only (`--permission-mode auto`) and only reminds.
Set `VISOR_AUTONOMOUS=1` to let it actually do tasks (`--permission-mode
dangerous`), in which case it runs in `VISOR_WORK_DIR` (default `~/repos`) —
point that at the repo you want it to touch.

Run it manually, then schedule it for the morning nudge:

```sh
./scripts/devin-check.sh                              # remind only
VISOR_AUTONOMOUS=1 VISOR_WORK_DIR=~/repos/myapp ./scripts/devin-check.sh

cp ~/repos/visor/scripts/com.user.devin-check.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.devin-check.plist   # weekdays 9:30
```

> This is the only background agent Visor uses, and it's **opt-in** — install it
> only if you want the scheduled nudge. The on-demand "Send to Devin" button
> needs nothing running in the background.

## Known limitations

- Concurrent edits (typing while an agent writes) resolve last-writer-wins.
- Task identity is the task's text — rewording a task resets its age.
- The expanded panel doesn't auto-dismiss on outside clicks (by design: it
  stays until you click the notch again).
- A chat written by an agent through MCP appears the next time you open that
  conversation; the app doesn't yet watch the chats directory for changes.
- Chat agents go through OpenRouter only. One key reaches essentially every
  model, so this buys a lot for one auth flow — but there's no direct
  Anthropic/OpenAI path.

## Building

`swift build` needs a full Xcode (16 or newer — Firebase requires a Swift 6
compiler). Command Line Tools alone can't build this package: SwiftPM asks for
a platform path only Xcode provides. CI on `macos-15` builds every push, so a
machine without Xcode can still verify a change.
