# Visor design system — handoff

The rules every Visor surface follows, and the components that encode
them. Everything here is in `Design.swift`, `Selectors.swift`,
`ChatSurfaces.swift`, `Composer.swift`, `TranscriptView.swift` and
`MessageBody.swift`. Onboarding, settings and any new surface reuse these
components and rules rather than restating them.

## Direction

Visor is a precise, quiet instrument that lives in the Mac. Its
personality is carried by four things and nothing else: the notch
silhouette, the dot-matrix status language, pixel-face kickers on labels
in the retro study, and the way its surfaces answer the pointer. Body
text is always the system face at reading size. Two studies share every
token: **clarity** ships; **retro** is a lab-rendered alternative that
swaps label face and radii only (`Design.Study`).

## Typography (`Design.Typography`)

| Role | Size / weight | Use |
|---|---|---|
| display | 20 semibold | finale titles, first-run headlines |
| title | 15 semibold | HUD conversation title |
| heading | 13.5 semibold | agent name, empty-state invitation, approval question |
| body | 13.5 regular, +3 leading | messages, composer (14 in the card, 16 in the HUD) |
| secondary | 12 | metadata, row subtitles, hints |
| caption | 11 | timestamps, steps, footers |
| label | 10.5 semibold, tracked 0.7 (retro: pixel 10, tracked 1.6) | section and panel headers, always uppercase |
| mono | 12 monospaced | code, tool names, shortcuts |

The HUD's text setting scales body, secondary and caption in the
conversation only. Chrome, rails and controls never scale; layout adapts
by rule (rails hide below 1180pt).

## Spacing (`Design.Space`)

2 · 4 · 6 · 8 · 12 · 16 · 20 · 24. Card content insets 14 horizontally.
Row height in selectors is 30 (42 when rows carry a second line).

## Controls (`Design.Metric`)

| Size | Points | Icon | Where |
|---|---|---|---|
| small | 24 | 11 | header buttons in the notch band, panel headers, chip accessories |
| regular | 28 | 13 | selector rows, action chips, identity control, example chips |
| large | 32 | 15 | composer round controls (plus, mic, send) |

Minimum pointer target 24pt. A control's size comes from this table, not
from its label. `IconButton` is the square icon control; `ActionChip` the
text button; `ExampleChip` the request suggestion; `ComposerPill` the
inline selector chip at `large`.

## Geometry (`Design.Radius`, `Design.Stroke`)

| Role | Radius |
|---|---|
| control | 8 |
| chip | capsule |
| popover | 12 |
| panel (HUD rail, approval, user bubble) | 14 |
| composer | 16 (HUD: 20) |
| card | 18 |
| surface (HUD backdrop) | 26 |

Nested corners follow the outer curve at the inset when the inset is
under 8pt (inner = outer − inset). Beyond that, the inner element uses its
own role; the eye no longer reads the two as concentric.

Strokes are one device pixel (`Design.Stroke.hairline` = 1 / backing
scale), never 1pt. Three colours: `edge` (white 10%) on raised surfaces,
`control` (white 16%) on controls that must read as one, `divider` (white
7%) inside surfaces. The focused composer swaps `edge` for `control`.

## Surfaces (`Design.Surface`)

Three levels on the card: **base** (the black card), **raised** (white 6%,
strong 9% — composer, chips, rails, approvals), **overlay** (opaque
`Design.Retro.bg` — every popover and menu, so the desktop never bleeds
into a list). Hover lifts by 7%, press by 13%, selection sits at 15%.

Assistant replies are unboxed: they are the card's own voice and read at
full measure. User turns sit in a raised-strong bubble with a 4pt corner
toward the sender.

The HUD backdrop is `regularMaterial` under a 62% black tint, faded by the
user's glass setting; under Reduce Transparency it is an opaque
`glassOpaque` fill. Rails are `rail` (white 4.5%) fills with no border,
sized to content, collapsible to their header.

## Ink (`Design.Ink`)

primary 92% · secondary 62% · tertiary 42% · faint 24% · link · warning
(orange, errors only) · destructive (red, Stop while running). Every
active, streaming, selected or current state uses the theme accent;
`Design.Retro.onAccent` is the ink on an accent fill.

## Motion (`Design.Motion`)

Four presets, all returned as `nil` under Reduce Motion:

| Preset | Curve | Use |
|---|---|---|
| quick | easeOut 0.12 | hover, press, selection, send-button state |
| standard | easeOut 0.2 | composer growth, rows appearing, panel collapse, scroll-to-latest |
| surface | spring 0.34 / 0.95 | card open, close, face swap |
| hud | spring 0.52 / 0.86 | HUD in and out |

Window management stays in AppKit and content motion in SwiftUI; the two
never animate the same change. Materials fade, content scales. Typing,
selection and direct manipulation are never animated.

## Interaction rules

- One recipient for ⌘↩ and ⌘. — the compact composer. The field itself
  sends on Return; Shift-Return inserts a newline.
- Escape steps back one level. Popovers dismiss on Escape and restore
  focus to the field.
- Streaming follows only within 48pt of the end; a Latest / New reply
  pill returns. Reading position is shared across the card and the HUD.
- Chips, round controls and rows opt out of keyboard focus
  (`.focusable(false)`); the field and the selectors' search own it.
- Every interactive control carries a stable `accessibilityIdentifier`
  of the form `visor.<area>.<control>`.

## Components

| Component | File | Role |
|---|---|---|
| `IconButton`, `ActionChip`, `ExampleChip`, `SectionLabel`, `RaisedSurface` | Design.swift / Selectors.swift | primitives |
| `SelectorList`, `SelectorRow`, `SelectorSearch`, `SelectorHeading`, `SelectorSegments`, `SelectorField`, `selectorSurface` | Selectors.swift | the picker family |
| `AgentIdentity`, `AgentSelector`, `StatusDot`, `EmptyInvitation` | ChatSurfaces.swift | agent identity and invitation |
| `ModelSelector`, `OptionsSelector`, `CLISelector`, `ModelMeta` | ModelSelectors.swift | model and options pickers |
| `Composer`, `ComposerField` | Composer.swift, ChatView.swift | the message field |
| `TranscriptView`, `MessageRow`, `MessageBody`, `ToolApprovalRow` | TranscriptView.swift, ChatView.swift, MessageBody.swift | the conversation |
| `HUDView`, `HUDPanelSlot`, `HUDLayout` | ChatView.swift, HUDPanels.swift | the HUD |
| `ComputerUseCard` | ComputerUse/ComputerUseIsland.swift | computer use |

## Verification

Every surface has a Design Lab scenario (`docs/design-lab.md`). Captures
prove layout, type, density and hierarchy; focus, window ordering, hover,
caret and the notch's real alignment are hardware checks listed in
`docs/design-brief.md`.
