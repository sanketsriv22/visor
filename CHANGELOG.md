# Changelog

All notable changes to Visor. The newest entry is shown under **What's New** in
the menu-bar dropdown, and published as the release notes for each version.

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
