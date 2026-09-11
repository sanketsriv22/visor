# Changelog

All notable changes to Visor. The newest entry is shown under **What's New** in
the menu-bar dropdown, and published as the release notes for each version.

## Unreleased — core redesign and a new introduction

- A design system (`docs/design-system.md`): six type roles, a 4pt grid, three control sizes, radii by role, device-pixel hairlines, three surface levels, four motion presets. Two studies share it; clarity ships.
- Chat: the agent's identity leads the card; an agent-first empty state with example requests; replies render as Markdown blocks and read unboxed at full measure; a transcript that follows only near the end; approvals on the accent.
- A composer modelled on ChatGPT's, shared by the card and the HUD.
- One selector family for model, reasoning and speed, CLI model and agent, sized to content.
- HUD: the conversation at a reading measure, rails sized to content and collapsible, a thicker glass.
- Computer use: the task in the composer's surface; current action, numbered steps and Stop.
- System font by default; Departure Mono stays for glyphs and the wordmark.
- The introduction is a narrated screen takeover on the real product. A voice paces every moment; the only things asked of you are an agent's name and connection, one Allow, and one Stop. It plays a bundled welcome video (`Resources/intro.mp4`) when one is present. Five bundled neural voices (Settings → Voice picks one, or any voice on the Mac); the mark breathes with the voice, rings spread from the notch, and a reticle locks onto the real control to press. The HUD has its own beat. Quiet sound cues, mute switches, a thin line of progress; no cards but the one form and the goodbye. Replayable from the menu-bar panel and Settings.
- Live conversation: a waveform beside the agent, in the card and the HUD, opens a GPT-Live voice session with the selected agent as its backend — you talk, the agent answers on its own model, the voice says it. Approvals can be answered by voice. Voice and barge-in in Settings → Voice.
- Keys report whether they work and what's left: OpenRouter's balance, this key's usage and limit, and OpenAI's acceptance, under each key in Agents, Voice and Secrets, with a Check button.
- Every dropdown in Settings is a visible control now: the choice on a panel with a chevron.
- Live conversation is the chat: your words stream into your turn as you speak, the reply streams as the agent's; the composer folds to one row with a waveform in voice mode, and the switch is beside the mic. Session events are logged to ~/Library/Logs/Visor/live.log.
- HUD text size is capped at 1.25×; the transcript no longer unpins when content grows under a pinned reader.
- The mark is re-rendered: a thicker tube in a glossy gradient of the palette, turning once every six seconds with a slow nod; the halo no longer draws a ring.
- A Design Lab (`Visor --design-lab`) renders every surface with isolated fixtures, including frame sequences.

## 1.0-beta.36 — 2026-09-02

- **Computer use: Visor can play chess for you.** ⌘⌃U on a chess.com or Lichess game and Visor reads the board straight out of the page — no screenshots, no guessing — and either draws the three best moves on the board as arrows, or plays them for you by dragging the pieces. Choose the engine's strength from 1320 Elo up, or full strength, and a response-time band so it doesn't answer instantly every move. It works as either colour, handles promotions and checks, and recovers on its own if it loses the thread. Set it up under Settings ▸ Computer Use.

- **Visor has a second face: chat.** Press ⌘⌃K, hit ⌘2, and type — replies stream straight into the notch. The card grows sideways when you switch; the notch stays the notch. Switch with the control in the notch's left shoulder (where VISOR used to sit) or ⌘1 / ⌘2.
- **Name your own agents.** Settings → Agents lets you create as many as you like, each on its own model — the list is fetched live from OpenRouter, so it's never a stale hard-coded menu — with an optional persona prepended to every conversation. One OpenRouter key is shared by all of them and lives in your Keychain, so you paste it once.
- **Agents run in the notch.** Send a task to a chat agent and it answers right there instead of opening a Terminal. CLI agents (Claude Code, Codex, Devin) work exactly as before.
- **Chats remember.** Visor embeds every turn on-device, so an agent can recall what you talked about weeks ago. Nothing leaves your Mac to do it and there's no embedding bill. Deleting a chat forgets it.
- **Export any chat** as markdown or JSON, or copy it to the clipboard.
- **⌘⌃K opens and closes the notch** from any app — no Accessibility permission needed.
- **Settings is a real window now**, with panes for Agents, Workspace, MCP and Memory. The menu-bar dropdown couldn't hold a form.
- **MCP, both ways.** Ready-to-paste setup for Claude Code, Codex, Cursor and Devin, plus new chat tools — agents can list, read and search your conversations, and `post_to_chat` writes back so their answer lands where you'll see it.
- **No more red warning under your tasks.** A missing API key isn't a failed run: it opens Settings on that agent instead. And no run outcome is permanent any more — the footer clears itself.
- **A third face: the HUD.** ⌘⌃M expands chat to full screen, with rails for your agents, open tasks, what Visor has learned and what you've dictated. Transparency and size are sliders in the HUD itself, because you can only judge either while looking at it. It grows out of the notch and collapses back into it.
- **Agents can do things, not just answer.** They read your note, add and complete tasks, load web pages, and run shell commands in your project folder. Anything irreversible asks first and shows the actual command; "Always" is remembered per agent and per tool.
- **Dictation.** ⌘⌃V or hold a modifier of your choosing. The notch widens into a live level meter while you speak, then transcribes and closes. Everything dictated is logged, and a cheap model can tidy punctuation and mishearings first.
- **Optional knowledge graph.** A cheap model extracts durable facts from your conversations and stores them as connected claims, so recall walks relationships instead of matching wording.
- **Per-message model, thinking effort and routing** in the composer, with models pinned per agent — the full OpenRouter catalogue stays behind a search.
- **Signed and notarized.** Visor ships with a Developer ID signature and a stapled ticket, and there's a DMG. This also stops macOS re-asking for Keychain and Accessibility permission on every update.
- **New app icon.**

## 1.0-beta.35 — 2026-07-15

- **Links on tasks.** Attach a URL to any task with the link button on its row — tap to open it in your browser, or right-click for Add / Edit / Remove link. Linked tasks show a filled blue link icon. The URL is tucked into the markdown as a trailing comment, so your notes stay clean and agents still read plain text.

## 1.0-beta.34 — 2026-06-24

- **Completed tasks tuck away.** Finishing a task sinks it to the bottom, and completed tasks collapse under a "N completed" toggle so they don't crowd your list.
- **"Add a task" is a button now.** The ➕ at the end of the title row drops a fresh task at the bottom of your unfinished list and puts the cursor right in it. Tapping a checkbox cycles open → doing → blocked — **finishing a task is long-press only**, so you can't complete one by accident.
- **Clean up by progress.** A new "Clean up — sort by progress" item in the note menu orders tasks untouched → in-progress → blocked → done.
- **Notch band tidied.** The open-task count now sits next to VISOR on the left of the notch, and the beam (share) button moved up beside the sharing indicator.
- **Editing fixes.** Backspace on an empty line removes it (and discards the note when it's the last empty line); empty new tasks are dropped when you click away; new tasks reliably scroll into view; and the drag handle stays under your cursor when reordering past a multi-line task.
- **Polish.** The scrollbar is hidden, the send/delete icons on each row glow on hover, and the old "hover a task →" hint line is gone.
- **For your AI agents (MCP).** The Visor MCP server now surveys tasks across **all** your notes, can set a task's status (doing / blocked / done) so an agent shows live progress right in Visor, and gives clear Full Disk Access guidance instead of returning an empty list.

## 1.0-beta.33 — 2026-06-23

- Update prompts now come to the front. "Check for Updates" and the available-update window appear on top of your other windows instead of opening behind them.

## 1.0-beta.32 — 2026-06-22

- **Arrow-key navigation between tasks.** Up/Down move the cursor between rows, preserving your column (it lands at the same spot, not the end), and move between a long task's wrapped lines before jumping rows.
- Beam links are now shorter and readable — `…/visor/beam/#s/<note-name>-xxxx` — and point at the kitalabs.dev domain.
- Empty notes and blank task rows no longer linger: an untouched new note is discarded when you leave it, and a blank row clears the moment you move to another line.
- The note auto-scrolls to keep a newly added task in view, and the drag handle now sits snug next to the checkbox.
- Removed the faint light line along the note's top edge.
- New look: a trefoil-knot mark is now Visor's app icon and menu-bar icon, and replaces the prism on the beam button (it still lights up as a spectrum on hover).

## 1.0-beta.31 — 2026-06-22

- Beam now creates a **live shared note** instead of a one-time copy: send someone the link and you both edit the same note, syncing in real time, character by character. Opening the same link again reopens that shared note instead of spawning duplicates.
- A beacon in the top band shows when a note is shared, with a live count of how many people are viewing it right now.
- Empty notes and blank task rows no longer linger: a brand-new note you never type in is discarded when you leave it, and a blank row vanishes the moment you move to another line.
- The task list now auto-scrolls to keep a newly added task in view when it lands past the bottom.
- Tightened the spacing between the drag handle and the bullet on the left of each row.
- Smoothed the notch hover affordance so the little pull-tab fades in instead of snapping.

## 1.0-beta.30 — 2026-06-20

- Fixed the updater never offering updates. The appcast advertised the marketing version where Sparkle expected the numeric build number, so "Check for Updates" always said you were up to date even when a newer version existed. It now compares build numbers correctly, so Check for Updates works from here on.
- The delete-note confirmation no longer appears hidden behind the note.
- Beam is now a prism light-ray button at the end of the note's title row, instead of being tucked in the menu — click it to open AirDrop / Messages / Mail. Hover it and the prism splits the light into a spectrum.

## 1.0-beta.29 — 2026-06-20

- Beam now uses the macOS share sheet: "Beam this note…" opens AirDrop / Messages / Mail. AirDrop a note to a nearby Mac and it drops straight onto that Mac's Visor — no link, no browser. ("Copy beam link" is still there for sending a link to remote friends, with an install fallback for anyone without Visor.)

## 1.0-beta.28 — 2026-06-19

- Beam a note to a friend: "Beam this note…" in the note menu copies a link that encodes the whole note. When they open it, a copy drops onto their Visor. The note travels inside the link itself — nothing is uploaded to or stored on any server.
- Agents update task progress live: the MCP server gained a `set_task_status` tool, so Claude (or any agent) can mark a task doing / blocked / done as it works, and Visor reflects it within a second or two.
- Switching between notes is now instant — it no longer rescans the notes folder or waits on disk while you switch.
- Move a task into a brand-new note: the task right-click "Move to" menu now offers "New note", which creates a note named after the task and moves it there.
- Typing a long task wraps to the next line immediately instead of stretching past the edge first.
- Refined brand icon: the menu-bar "Knot" mark now uses smooth curved strokes.

## 1.0-beta.27 — 2026-06-19

- Custom brand icon in the menu bar: the old SF Symbol checklist is replaced with the Visor "Knot" mark — two interlocking V shapes with an alternating over/under weave. Rendered as a macOS template image so it auto-colorizes for light and dark menu bars.

## 1.0-beta.26 — 2026-06-19

- Replace the hand-rolled updater with Sparkle. Updates are now signature-verified (EdDSA), handle /Applications privilege elevation properly, and check silently in the background — no more "Check for Updates" lag or failed swaps.
- Faster update checks: Sparkle fetches a small appcast XML instead of hitting the GitHub API.

## 1.0-beta.25 — 2026-06-19

- Fix self-updater silently failing when Visor.app was installed by a different macOS user. The swap script now moves the old bundle out of the way (which only needs write permission on /Applications) instead of trying to rm -rf its contents.
- Claude Code now runs with `--dangerously-skip-permissions` by default, so tasks sent from Visor don't stop to ask for approval on every tool call.

## 1.0-beta.24 — 2026-06-19

- Delete a note from the switcher (⧉): a new "Delete this note" permanently removes the current note (with a confirmation, since — unlike Archive — it can't be undone).
- Order notes in the switcher: a "Sort by" submenu lets you list notes by Name (A–Z), Recently updated, or Recently created. Your choice persists. (Manual drag-ordering isn't possible inside a macOS dropdown.)
- "Check for Updates…" now shows progress in a small floating pill centered just below the notch (with a spinner: Checking → Downloading → Installing → Restarting), instead of text in the menu — which closed the moment you clicked, hiding all feedback. Keeps it visible regardless of how crowded the menu bar is; "You're on the latest" / errors flash there briefly. (Updates already relaunch the app for you automatically; this just makes that visible.)
- New "Devin (Cloud)" agent: instead of running a local CLI, it creates a Devin cloud session through the Devin REST API and opens the session in your browser / the Devin desktop app so you can watch and steer it. Add your Devin API key (Personal key `apk_user_…`) under Settings → AI Agents → Devin (Cloud); it's stored in the Keychain. Pick it from the menu-bar "Send tasks to" list, then the ✈ on a task starts a session.

## 1.0-beta.23 — 2026-06-19

- Run agents in a Terminal window you can watch (new default), instead of silently in the background. Toggle it under the menu bar → "Run agents in" (or Settings). Terminal mode opens each send in its own window, streams the agent live, and stays open after it finishes; Background still runs it quietly and captures output to a log. Any API key you've stored is injected the same way in both modes.
- Claude Code runs as a real interactive session in Terminal mode: sends launch `claude "<task>"` (not headless `claude -p`), so you see it think and use tools and can follow up in the same window, using your existing CLI login — no API key needed. Background mode still runs it headless with `-p`.
- Pick the project an agent works in: a new "Run in folder" menu (and Settings) lets you choose any local repo — your git repos under `~/repos` are listed for one-click selection, or browse to any folder. Sends then run inside that repo with access to all its code, and the prompt frames the task as a task for that project. The choice persists across launches.
- Archive notes: the note switcher (⧉) now has "Archive this note" — it moves the note into `Documents/Visor/Archive`, out of the switcher but safe on disk. Archived notes appear under an "Archived" submenu where one click restores them.
- Easier drag-to-reorder: the drag handle now has a generous grab zone around the ≡ glyph, so you can start a drag from the general area instead of having to land your cursor exactly on the three lines.
- Tighter task list: rows sit closer together (the enlarged drag handle had bloated each row's height).
- Settings now shows the actual command for each run mode (e.g. Claude Code: Terminal `claude <prompt>` vs Background `claude -p <prompt>`), instead of only the `-p` form — so it's clear the Terminal/Background toggle is what picks which one runs.

## 1.0-beta.22 — 2026-06-19

- Right-click a task to move it to another note (or delete it).
- Hovering a one-line task no longer makes it wrap — the send/delete actions float over the row's right edge with a fade instead of pushing the text.
- Cleaner rows: the drag handle, status circle, and task text are vertically centered on the line, and the handle is more visible.

## 1.0-beta.21 — 2026-06-18

- Press-and-hold a task's checkbox to jump straight to done (hold again to reopen) — no more clicking through doing/blocked to complete something. A quick tap still cycles the states.

## 1.0-beta.20 — 2026-06-18

- Drag-to-reorder is responsive again: after dropping a task you can immediately grab another. The reorder/settle animation had a slow bouncy tail that kept the list "animating" and blocked the next grab; it's now a quick, critically-damped settle.

## 1.0-beta.19 — 2026-06-18

- Drag-to-reorder now tracks your cursor tightly. The drag was measured in the row's own moving coordinate space, which fed back on itself and made it glitch in place; it's now measured in global (screen) space.

## 1.0-beta.18 — 2026-06-18

- Fixed the buggy drag-to-reorder. Rewrote it with a correct neighbor-swap algorithm: the dragged row stays glued to the cursor while the others slide cleanly into place. (The previous version double-counted the drag distance, causing the chaos.)

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
