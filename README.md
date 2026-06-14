# Visor

A sticky note that lives inside your MacBook's camera notch — invisible until
you click the notch, at which point it slides down beneath it. Click the notch
again and it tucks itself away. Notes are plain markdown on disk, exposed to
AI agents (Devin, Claude Code, anything MCP-aware) through a small MCP server,
so an agent can read your stickies, notice what you haven't done, and nudge
you — or just do it.

```
~/StickyNotes/sticky.md   ← single source of truth (plain markdown)
        ▲            ▲
   notch app     MCP server ──► local agents (Claude Code, …)
                      │
                 git sync ────► private repo ──► Devin (cloud)
```

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/sanketsriv22/visor/main/install.sh | bash
```

Clones, builds, and installs `Visor.app` to `/Applications`. Requires git and a
Swift toolchain (`xcode-select --install`). Or build from a local checkout:

```sh
./scripts/make-app.sh        # builds Visor.app and installs it to /Applications
```

## The app

- Click the notch → the note slides down under it. Click the notch again
  (or press Esc) → it slides away. Until then it stays put.
- Tasks are checkboxes: type in the **Add a task…** field (Enter for the next),
  click the circle to complete, hover a row to delete. On disk a task is just
  `- [ ] …` / `- [x] …`, so agents read and write the same file.
- A **menu-bar icon** (the only visible chrome) toggles the note and quits the
  app. No Dock icon; nothing else visible while collapsed.
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

## The MCP server

```sh
cd mcp-server
npm install && npm run build
```

Tools exposed: `read_sticky`, `list_tasks` (with `firstSeen`/`ageHours` per
task and an `older_than_hours` filter), `add_task`, `add_note`,
`complete_task`. First-seen timestamps are kept in `~/StickyNotes/.meta.json`,
maintained automatically — the note file itself stays clean.

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

> The git-sync scripts (`sync-stickies.sh`, `com.user.sticky-sync.plist`) are
> now **optional** — only needed if you also want a *cloud* Devin session (or
> another machine) to read the notes over GitHub. The local CLI path above
> doesn't use them.

## Known limitations (v1)

- Single note file; no multiple stickies.
- Concurrent edits (typing while an agent writes) resolve last-writer-wins.
- Task identity is the task's text — rewording a task resets its age.
- The expanded panel doesn't auto-dismiss on outside clicks (by design: it
  stays until you click the notch again).
