# Design Lab

The Design Lab renders Visor's production views with scripted state to PNG,
so a UI change can be looked at without anyone sitting in front of the
MacBook. It exists because the app runs on a machine that is only reachable
over SSH, and an SSH session cannot take screenshots.

## Running it

From the development machine:

```sh
scripts/design-lab.sh                     # every scenario, current theme
scripts/design-lab.sh out --theme all     # themed scenarios under every theme
scripts/design-lab.sh out --scenario hud  # one scenario
```

The script launches a second, short-lived Visor instance on the MacBook with
`--design-lab`, waits for it to exit, and copies the folder back. Open
`index.md` for a table of every capture with what to look at, or read the
PNGs directly. `log.txt` says which scenarios rendered.

Directly on the MacBook:

```sh
open -n -W /Applications/Visor.app --args --design-lab /tmp/lab --theme all
```

Transitions as frame sequences: `scripts/design-lab.sh out --scenario
takeover-open --frames 14 --every 250` writes `takeover-open-f00.png` …
`-f13.png` a quarter-second apart with live timing, so the reveal, the
practice driver and the pixel field can be judged as motion.

Font can be pinned the same way UserDefaults arguments always work:
`--args --design-lab /tmp/lab -visor.fontFamily "Departure Mono"`.

## Scenarios

| Name | Shows |
|---|---|
| `notes` | Notes face with tasks in each state |
| `chat-empty`, `chat-no-agents` | Chat with an agent and nothing said; the first-use state |
| `chat-waiting`, `chat-streaming` | Waiting on the first token; mid-stream with partial Markdown |
| `chat-complete`, `chat-formatted` | A short exchange; a long formatted reply (headings, lists, code, table, quote) |
| `chat-approval`, `chat-error` | Tool approval in the compact card; a failed send |
| `composer-multiline` | The composer grown to its limit |
| `computer-use` † | Computer Use card, idle |
| `hud`, `hud-streaming` | The HUD with pinned rails |
| `menu-panel` † | The menu-bar dropdown |
| `settings-appearance` † | Settings → Appearance |
| `takeover-intro`, `-notch`, `-open`, `-agent`, `-agent-key`, `-task`, `-approval`, `-trouble`, `-milestone`, `-drive`, `-stopped`, `-finale` | The introduction at each moment, over a dimmed screen as the app layers it (`-open` is for `--frames`) |
| `selector-models`, `selector-options`, `selector-agents` | The selector family's content |
| `computer-use-running`, `computer-use-done` | Computer use mid-task and finished |
| `composer-parts` | The composer's controls in isolation, one variant per row |

† themed: rendered once per theme with `--theme all`.

## Isolation

- Stores live under `<out>/.fixtures` and are deleted afterwards: `ChatStore`,
  `KnowledgeBase`, `KnowledgeGraph` and a `NotesStore` created with
  `ephemeral: true`, which never writes UserDefaults.
- Agents come from `AIRunner(fixtureProviders:)`; nothing is read from
  `ai-providers.json`.
- The chat controller is `offline`: no model catalogue fetch, no sends.
- The theme and HUD rail layout are set in the volatile argument domain, so
  the user's own choices are neither read into captures nor changed.
- The lab runs before the single-instance check, Keychain migration, status
  item, shortcuts and gesture taps, so none of them start.

## What a capture can and can't prove

A capture is a real render of the real views, so layout, typography,
density, hierarchy and theme are what you'd see. Materials (`.ultraThin`)
render approximately: the lab's window is on screen at zero alpha, so the
HUD's glass samples whatever is behind it at the time.

A capture cannot show window ordering, key status, focus, the caret, hover,
or the notch's real alignment. Those are the regression scenarios in
`docs/design-brief.md`, and they stay unverified until run on hardware.

Time-dependent visuals (the dot-matrix indicator, the takeover's pixel
field and the turning mark) are captured at whatever frame they were on.

## The hero mark

`Resources/hero-sheet.png` is a 6×6 sprite sheet (36 frames, 320px each)
of the trefoil turning, rendered in Blender through its MCP: a bevelled
trefoil curve, a purple principled body mixed with an emissive rim by
Fresnel, a key and a rim light, an orthographic front camera, Cycles at 40
samples with fog-glow in the compositor, film transparent. `HeroMark`
plays it at 24 fps and falls back to the flat `BeamMark` when the sheet is
missing.

## Adding a scenario

Add an entry to `DesignLab.scenarios()` in `DesignLab.swift`. Build the view
from `Fixtures` — use `compact(_:chat:)` for the card on a synthetic screen
top, `hud(chat:)` for the HUD, or host any view directly. Give it a size,
say whether it's themed, and write one line saying what to look at.
