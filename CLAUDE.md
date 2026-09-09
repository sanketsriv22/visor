# Visor — notes for Claude

Visor is a SwiftUI/AppKit accessory app that lives in the MacBook notch.
Sources are in `app/Sources/Visor`; the package targets macOS 13 and must
keep doing so unless the owner explicitly raises it.

## Before any UI work

Read `docs/design-system.md` (tokens, components, rules — the source of
truth for every surface, onboarding included) and `docs/design-brief.md`. The
brief holds the design principles, the window and
focus invariants that earlier bugs paid for, the transition spec, and the
regression scenarios. Do not undo an invariant to fix a symptom.

## Build and ship

- Neither development machine has Xcode. `swift build` does not work
  locally; `swiftc -parse <file>` catches syntax only. **CI is the
  type-check**: push the branch, wait for the workflow, download
  `Visor-app`, install on the MacBook. See the pipeline notes in memory.
- `scripts/make-app.sh` installs into `/Applications` by default. Do not run
  it on a machine where the user's Visor is installed unless that is the
  intent.
- Every install invalidates the MacBook's Screen Recording and Accessibility
  grants (ad-hoc signing).

## Design Lab

`Visor --design-lab <out-dir> [--scenario <name>] [--theme <mono|purple|…>]`
renders production views with fixture state to PNG, isolated from personal
data (temp stores, no model calls, no sync). Run it on the MacBook over SSH
with `scripts/design-lab.sh`. Details in `docs/design-lab.md`.

## Conventions

- Text goes through `Design.Text`; colours through `Design.Ink` /
  `Design.Surface` / `Design.Retro`; radii and spacing through
  `Design.Radius` / `Design.Space`. Never hard-code Departure Mono for a
  label — only for glyphs and the wordmark.
- `onChange(of:)` uses the single-value closure: the two-value form needs
  macOS 14.
- Assistant replies render through `MessageBody` (MarkdownUI). Transcripts
  are `TranscriptView`; composers are `Composer`. Do not add a second one.
- Animations that move surfaces go through `Design.Motion` so Reduce Motion
  is honoured.
- Give interactive controls a stable `accessibilityIdentifier`
  (`visor.<area>.<control>`).
