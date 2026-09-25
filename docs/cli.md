# The `visor` terminal client

`visor` is Visor's agents in a terminal, in the shape of OpenCode and its
kind: a full-screen transcript, an input line, pickers for agents, models
and past chats, and tool calls that ask before they run anything.

It reads the same files as the app — `~/StickyNotes/ai-providers.json` for
agents, the Keychain for keys, `~/Documents/Visor/chats` for conversations
— so a chat started at the prompt shows up in the notch, and the other way
round. The current directory is the project folder the agent works in.

```sh
visor                          # full-screen client, in this folder
visor run "prompt" [-a NAME]   # one turn, streamed to stdout; --yes runs tools without asking
visor agents                   # what Visor knows
visor sessions                 # recent chats
```

Inside: `/agent`, `/model`, `/sessions`, `/new`, `/help`, `/quit`. Escape
stops a reply; ↑↓ scroll the transcript; ctrl+n starts a new chat.

Tools: `run_shell` (asks each time, or `a` to allow for the session) and
`fetch_url`. Hosted agents get them; CLI agents (Claude Code, Codex) bring
their own and are resumed per conversation like the app does.

## Building

It is the `visor-cli` product of the Swift package in `app/`. CI builds
it with the app, `scripts/make-app.sh` copies it into the bundle as
`Contents/MacOS/visor`, and `scripts/install-macbook.sh` links that onto
the PATH. The sources in `app/Sources/VisorCLI/Shared` are symlinks into
`Sources/Visor`: one copy of each portable file, compiled into both.

Linux: the client is Foundation-only apart from the Keychain and Combine's
`ObservableObject` in the shared stores; those are the two seams to cut
for a Linux build, with keys from a config file instead.
