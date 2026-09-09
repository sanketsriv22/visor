# Visor design brief

Read this before any UI change. It is short on purpose: these are the rules
the product's identity depends on, followed by the window and focus
invariants the code already protects, and the transitions that have to keep
working. General SwiftUI guidance supplements this; it does not override it.

## What Visor is

The notch is a persistent piece of the Mac that becomes an interactive
surface. Everything Visor shows — notes, chat, dictation, computer use, the
HUD — comes out of the notch and goes back into it. The product feels right
when every surface reads as the notch opening up, and wrong the moment
anything reads as a window that happened to appear near the top of the
screen.

## Principles

1. **The notch is the origin.** Opening, expanding, and returning all
   animate from the notch's centre. Two motion origins fight; one origin is
   what makes the HUD feel like the notch unfolding rather than an
   unrelated window.
2. **Compact is for capture and short exchanges; the HUD is for sustained
   work.** The card holds a note or a few turns of chat. When a conversation
   gets long or needs the rails (agents, tasks, memory, dictation), the HUD
   is the place — not a taller card.
3. **State survives surface changes.** The draft, the selection, the
   conversation and the reading position are the same object under every
   face. Switching notch ↔ HUD must never lose a draft or jump the reader to
   the bottom.
4. **Readable text wins over theme.** The vintage-computing identity lives
   in pixel glyphs, the wordmark, dot-matrix indicators and sharp corners.
   Body text is the system font by default (Departure Mono is the pixel
   alternative in Appearance); it is never forced pixel for its own sake.
5. **Disclose progressively.** Model, send and stop are one click away;
   effort, speed, tools and export fold behind one control. Agent identity
   (name, model, whose account) is always legible. Nothing is shown at rest
   that isn't needed at rest. The composer is modelled on ChatGPT's — a
   soft pill, reading-size text at 1.5 line height, a row of round 32/36pt
   controls in its order (plus, model chip · mic, send) — because that is
   the composer people's hands already know.
6. **Behaviour is design.** Focus, keyboard shortcuts, dismissal, hover,
   press and click-through get the same attention as colour and spacing.
   `.plain` buttons with no press feedback are a bug, not a style.
7. **Bigger targets, fewer of them.** A 20pt icon strip is a puzzle, not a
   toolbar. Consolidate before adding.

## Type and colour

- Every text style comes from `Design.Text` (`SettingsKit.swift`,
  `RetroTheme.swift`). Chat body text is `13.5 × hudScale`. No raw
  `.system(size:)` in new code; use the scale.
- Colours come from `Design.Ink` / `Design.Surface` (on the black card) and
  `Design.Retro` (themed surfaces: Settings, menu panel, computer use). Do
  not invent a white opacity.
- Pixel glyphs (`RetroIcon`, `Glyph`) and the `VISOR` wordmark keep Departure
  Mono explicitly via `Design.Text.face`. Labels never do.
- Radii come from `Design.Radius`; spacing from `Design.Space`.

## Window and focus invariants (already in the code — keep them)

These are documented in `NotchWindow.swift`, `StickyView.swift` and
`ChatView.swift`. Each one was earned by a bug.

- **The card's window never resizes between faces.** It is sized to the
  screen while open so notes, chat and the HUD animate inside a window that
  never moves. Every flash ever chased came from resizing the window while
  SwiftUI still held content for the old size. (`applyFrame`)
- **The HUD is its own window.** It is created at full size and only ever
  shown or hidden. That is what stopped the menu bar flashing. SwiftUI
  cannot interpolate geometry across windows, so the HUD scales out of the
  notch instead of matching geometry with the card. (`showHUD`, `HUDRootView`)
- **The card retracts before its window is ordered out**, and the HUD's
  window is ordered out only after it has finished shrinking. Ordering a
  window out at frame one cuts the animation off. (`panelWork` delays: 0.42s
  after entering the HUD, 0.62s after leaving)
- **The card holds the union of both faces' sizes while open.** Switching
  notes ↔ chat is a pure SwiftUI morph of one chrome view; the contents
  cross-fade inside it. (`morphingCard`)
- **The mode switcher is positioned off the notch, not the card.** The card's
  width animates; the notch cannot move. (`switcherDistance`)
- **The panel is non-activating and becomes key only when something needs
  it.** The composer explicitly requests key status and restarts the caret
  timer, because AppKit only starts it for a key window. (`ComposerTextView`)
- **Exactly one recipient for ⌘↩ / ⌘.** The HUD root is mounted at the same
  time as the card, so only the compact composer claims the chord; the field
  itself sends on Return. Return sends, Shift-Return inserts a newline.
- **Esc steps back one level**, not straight out: history → chat → closed;
  HUD → chat.
- **Clicks on the notch while the HUD is up are caught by a window-level
  monitor**, because a SwiftUI hit target lost to the glass panel.
- **Materials fade; content scales.** A material being scaled is rasterised
  mid-animation and re-rendered sharp at the end, which reads as a tone
  shift. The HUD's glass only ever animates opacity. (`HUDView`)
- **Reduce Motion and Reduce Transparency are honoured.** `Design.Motion`
  returns `nil` animations when Reduce Motion is on, and the HUD swaps its
  material for an opaque fill under Reduce Transparency.

## Transitions

Each transition has one origin, one curve, and a defined result if reversed
midway. Durations are the ones in the code; change them together or not at
all.

| Transition | Origin | Curve | Focus | Reversed midway |
|---|---|---|---|---|
| Closed → notes / chat | notch centre, card scales from 0.02 at `.top` | spring 0.34 / 0.95 | panel takes key; composer or note field becomes first responder | collapse spring runs from the current frame; window shrinks 0.32s after |
| Notes ↔ chat | card chrome morphs 420 ↔ 530 wide | spring 0.34 / 0.95; contents cross-fade 0.16s | draft and note stay in memory | the morph reverses from its current width |
| Chat → HUD | card retracts into the notch; HUD centre scales from 0.04 at `.top`; rails slide in from the screen edges | spring 0.52 / 0.86 | HUD window is key; card window ordered out at 0.42s | `toggleHUD` again sets mode `.chat`; the pending order-out is cancelled |
| HUD → chat | reverse of the above | same | card takes key first so the composer is typeable while the HUD shrinks | the pending order-out is cancelled |
| HUD → closed | HUD shrinks straight into the notch; the card never shows | spring 0.42 / 0.86 | panel resigns key | reopening resumes into the HUD (`hudResumeKey`) |
| Dictation start / stop | notch widens symmetrically by 96pt each side; level meter in the pill | listening pill's own opacity | none — dictation never steals focus | stopping mid-fade just reverses |
| Reply streaming | none; the transcript follows only within 48pt of the end | 0.2s ease on new turns | composer keeps focus | scrolling up stops following; the Latest pill returns |

### Regression scenarios

Exercise these on the real notch after any change to `NotchWindow.swift`,
`StickyView.swift`, `HUDView` or the composer. They are the ones that have
broken before.

1. Rapid toggles: ⌘⌃K six times in two seconds. No stranded window, no
   half-open card, key status ends where the visible surface is.
2. Open while a reply is streaming. The transcript is at the bottom and
   keeps following; the composer is focused.
3. Dictate with the card closed. The pill appears beside the notch, text
   lands in the frontmost app, nothing steals focus.
4. Enter the HUD mid-draft, edit, return. The draft is identical; the caret
   is in the compact field; the reading position is the same message.
5. Scroll up during a stream; send a message. The transcript pins back to
   the end for your own turn.
6. Chat → HUD → chat within 0.3s. No frame shows both faces; no window is
   left ordered in.
7. Reduce Motion on. Every transition above completes instantly with no
   intermediate frame; nothing is left invisible.
8. External display without a notch, and a second display. The strip is
   drawn at the top centre; the HUD covers the notched screen only.

Items 1–8 are hardware checks. Record them as unverified until someone has
run them on a notched MacBook; a screenshot from the Design Lab cannot prove
focus or window ordering.

## Onboarding

The introduction is a screen takeover built from the product's own
components (`docs/onboarding-concepts.md` has the two concepts and the
choice). Eight moments, each advancing when the real thing happens:
wake (the mark rises from the notch) → summon with the real shortcut →
connect a detected agent, add a key, or go on with a labelled stand-in →
send a pre-filled first task and answer its approval → let a scripted
driver work a practice window → stop it and continue → ask something of
your own → return into the notch. The one question it answers on every
step and again at the end is *how do I get Visor back?*

Rules the takeover keeps:

- A panel at the notch's level, above the notch's windows, never key, with
  real transparent holes for the card, the notch's click band and the
  practice window, so clicks fall through to them. Hidden during a
  Settings excursion; back when Settings closes, re-checking what changed.
- It advances on real state (`UIState`, `ChatController` approvals and
  streaming, `PracticeDriver`), never on timers except the reveal and
  short pauses after a success.
- Progress persists past connect, the first task and the practice
  (`visor.intro.progress`). Skip and Back are always one click away;
  replay from the menu-bar panel or Settings starts fresh.
- Practice computer use is scripted, and says so: `ComputerUseAgent` will
  not drive Visor's own windows. The real computer-use face is one click
  away afterwards.
- Reduce Motion turns off the pixel field, the sweep and the typing;
  Reduce Transparency is inherited from the surfaces underneath.

## Verification loop

Every UI change ends with: build (CI) → install to the MacBook → run the
Design Lab scenarios → look at the captures → exercise the interaction on
the real notch where the scenario needs it → capture the result. Say which
conclusions came from source and which from something you actually observed.

The Design Lab (`Visor --design-lab <dir>`) renders the production views
with fixture state, isolated from personal data, and writes PNGs. See
`docs/design-lab.md`.
