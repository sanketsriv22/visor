# Changelog

All notable changes to Visor. The newest entry is shown under **What's New** in
the menu-bar dropdown, and published as the release notes for each version.

## 1.0-beta.17 — 2026-06-18

- Premium drag-to-reorder: dragging a task's handle is now a live reorder — the dragged row lifts (scale + shadow) and follows your cursor while the others smoothly slide aside. Replaces the old drop-target + orange-line interaction.
- More polish: tasks animate in and out when added/removed, and the checkbox gives a little pop when you change a task's state.

## 1.0-beta.16 — 2026-06-18

- Per-task agent indicator: while an agent is running for a task, that row shows a spinner — so with concurrent sends you can see exactly which tasks are in flight, not just the total in the footer.

## 1.0-beta.15 — 2026-06-18

- Concurrent sends: you can now fire a task at an agent while earlier ones are still running, instead of waiting for each to finish. The footer shows how many agents are working, and every run keeps its own log.

## 1.0-beta.14 — 2026-06-18

- Keyboard shortcuts now work in the note: ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z (copy, paste, cut, select-all, undo). As a menu-bar app Visor had no Edit menu to route them — added one.

## 1.0-beta.13 — 2026-06-18

- Sturdier autosave: edits save 0.35s after you stop typing, unsaved edits are flushed every ~1.5s even during continuous typing, and the note saves whenever the app loses focus — so an accidental or forced quit loses as little as possible.

## 1.0-beta.12 — 2026-06-18

- Multiple notes: each note is now its own file in `~/Documents/Visor/`, named by its title. Use the ⧉ menu beside the title to switch between notes or create a new one. The active note is mirrored to the agent path, so the MCP server / agents always read whichever note is showing. Your existing note is migrated in automatically.

## 1.0-beta.11 — 2026-06-18

- Smoother open: the per-row hover icons (✈ send, × delete, drag handle) no longer flash for a split second as the note slides down. Hover affordances are suppressed until the open animation settles.

## 1.0-beta.10 — 2026-06-18

- The open note now closes only when you click the notch itself — the same spot that opens it. Clicking the menu-bar shoulders beside the notch (where VISOR and the task count sit) no longer closes it.

## 1.0-beta.9 — 2026-06-18

- New Settings window (menu bar → Settings…): add agent CLIs, and for ones that authenticate with a key (e.g. `codex` → `OPENAI_API_KEY`), store the key securely in the macOS Keychain. The key is injected as an env var only when that agent runs, and never touches the config file.

## 1.0-beta.8 — 2026-06-18

- Choose your AI agent in settings: the menu-bar "Send tasks to" submenu picks Devin or Claude Code (add your own in `~/StickyNotes/ai-providers.json`). The per-task ✈ button sends that task to whichever agent you've chosen (#4).
- Sending is now per-task via the ✈ on each row; the old bulk "Send to Devin" button was removed.

## 1.0-beta.7 — 2026-06-18

- Send a single task to Devin: hover a task and click the ↗ to send just that one. The "Send to Devin" button still sends all open tasks (#3).

## 1.0-beta.6 — 2026-06-18

- Tasks now cycle through four states — click the circle to go open → doing → blocked → done, each with its own glyph and color (#8). Saved on disk as `[ ]` / `[/]` / `[!]` / `[x]`, and the MCP server reports the status so agents still see doing/blocked tasks as not-done.

## 1.0-beta.5 — 2026-06-18

- Drag tasks to reorder them: grab the handle (≡) on the left of a row and drag; an orange line shows where it'll drop. The new order is saved (#7, #6).

## 1.0-beta.4 — 2026-06-18

- Single-instance lock: launching Visor while it's already running now brings the existing note down instead of starting a second copy. Prevents two copies from racing on the notes file and clobbering each other.

## 1.0-beta.3 — 2026-06-18

- Long tasks now wrap onto multiple lines instead of being cut off at the edge (#2).
- Clicking the very top of the notch now closes the note while it's open (#5).
- Smoother expand animation — the card no longer overshoots and drops too low (#1).

## 1.0-beta.2 — 2026-06-18

- Version and What's New now display fully offline — Visor reaches the network only when you click "Check for Updates…".
- "What's New" groups changes by release instead of one merged list.

## 1.0-beta.1 — 2026-06-18

First public beta.

- Sticky note hidden behind the MacBook notch — click the notch to slide it down, click again to tuck it away.
- Tasks are clickable checkboxes with an "Add a task…" field; click the circle to complete.
- Editable note title (stored as a markdown heading).
- "VISOR" and the open-task count sit in the shoulders beside the notch.
- The note emerges from behind the notch, with no seam at the bottom lip.
- "Send to Devin" runs the local Devin CLI on your open tasks.
- Menu-bar icon: show/hide, version and What's New, check for updates, and quit.
- One-click self-update that downloads the latest build and relaunches.
- Minimal drop shadow; app identity com.kitalabs.visor.
