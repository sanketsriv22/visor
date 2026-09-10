# Onboarding — two concepts, one recommendation

Both concepts run on the design system in `docs/design-system.md` and reuse
the product's own surfaces: the compact card, `AgentIdentity`, `Composer`,
`ToolApprovalRow`, the computer-use card and the HUD. They differ in where
the story is told from and what the signature moments are.

## What the product can actually do (source-level findings)

- **Agents.** Hosted models through OpenRouter with a key
  (`OpenRouterClient.hasKey`), or local CLIs already on the Mac — Claude
  Code, Codex, Devin — whose sign-in state `CLIAccounts` can read. A
  scripted turn (`ChatController.demoNextSend`) exists for a first exchange
  without either.
- **Tools and approval.** Hosted agents can run tools; anything that needs
  approval stops on `ToolApprovalRow` and resumes through
  `approvePending`. This is the real control loop, not a demo.
- **Computer use.** `ComputerUseAgent` reads the frontmost app through
  Accessibility, clicks and types, and refuses to target Visor's own
  windows for the length of a run — so a practice window owned by Visor
  can only be driven by a scripted driver, never by the real agent.
  Permissions: Accessibility (`AXIsProcessTrusted`) and, for capture,
  Screen Recording.
- **Windows.** The card is a non-activating panel at status-bar level; the
  HUD is its own window; the takeover sits above both with a transparent
  hole cut for them and is never key.

## Concept A — "Wake" (recommended)

Visor wakes up inside the Mac, from the notch outward, and each capability
is revealed by the user exercising it.

Storyboard:

1. **Reveal.** The screen dims with a CRT sweep. The 3D mark rises *out of
   the notch* (not the screen centre), turns once, and settles above it.
   One line: *An agent lives in your notch.* Below: *Press ⌘⌃K — or click
   the notch.* Signature: the mark's rise and the pixel bloom that follows
   it out of the notch.
2. **Summon.** The user presses the real shortcut or clicks the ring. The
   card opens on chat. Pixels burst from the notch. The guide moves beside
   the card.
3. **Connect.** The guide reports what it found: *Claude Code is on this
   Mac, signed in as you@…* with **Use Claude Code**, or *Add an OpenRouter
   key* (Settings opens; the takeover hides and returns when Settings
   closes, re-checking the key), or **Skip for now** (the first task runs
   on a scripted stand-in, labelled). Success lights the agent's status dot
   in the real identity row.
4. **First task.** The composer is pre-filled with an editable request:
   *What's the biggest file on my Desktop?* The user sends it. With a real
   hosted agent, the tool approval appears — the guide names it: *It asks
   before it runs anything. Allow it.* The result streams in. With the
   stand-in, the same approval and result are scripted and marked as such.
   Signature: the first reply's arrival — a pixel burst and the reply
   settling in.
5. **Practice.** A practice window opens below the card: an expense
   report with three lines and an empty *Total* field, labelled
   *Practice — nothing here is real.* The guide: *Now let it drive.* The
   user clicks **Run**. A cursor ring glides row to row (each row lights as
   it is read), then to the field, and types the total digit by digit.
   Signature: the handoff — a beam from the notch to the practice window,
   then the cursor's first move.
6. **Control.** While it types, the guide asks: *Press Stop.* The run
   halts between actions; the guide: *Stopped. Nothing lost.* **Continue**
   resumes and finishes; the total lands; a check pulses.
7. **Yours.** *Your turn.* Three suggestions land in the composer on
   click; the guide mentions ⌘⌃M for the HUD and ⌘⌃V for dictation as
   optional. Advances when the user sends anything, or on **I'm done**.
8. **Return.** *Visor lives in the notch. ⌘⌃K brings it back.* The pixels
   rush into the notch, the scrim dissolves, the card stays open.

Copy is one line per moment, conversational, with the next action named.
Skip is always top right; Back returns to the previous moment; progress
persists at connect, first task and practice.

## Concept B — "Field guide"

The HUD opens first, as a full-screen guide: each rail panel and the
conversation column animate in as the guide explains them, with a
practice conversation already populated. The user then collapses the HUD
into the notch and repeats the summon. Signature moments: the HUD
unfolding panel by panel; the collapse into the notch.

Strengths: shows the whole product at once; excellent for a demo. Weaker
where it matters: it starts from the least common surface, it explains
rather than lets the user do, and the first success arrives late.

## Recommendation

**A.** It starts where Visor lives, every step is the user doing the real
thing, the first visible success comes within a minute, and control is
taught by actually stopping something. It maps onto the working
capabilities exactly, including the one honest limitation (practice
computer use is scripted because the real agent will not target Visor's
windows), and it ends by drilling the one fact a notch app has to leave
behind.

## Signature transitions (A)

| Moment | Motion |
|---|---|
| Reveal | mark rises from the notch centre (spring `hud`), pixel bloom follows it, wordmark types |
| First success | burst from the notch on the reply's arrival; the reply settles with the transcript's own `standard` ease |
| Handoff to computer action | a beam draws from the notch to the practice window (`standard`); the cursor ring's first glide is a `surface` spring |
| Completion | the total's field pulses once on the accent; a check draws on |
| Return | the guide's bubble and cheat sheet fade; pixels stream into the notch; the scrim dissolves (`hud`) |

Under Reduce Motion every one of these is a single frame.


## What shipped (v4, 2026-09-09)

Rebuilt on the mechanics HeyClicky actually uses, read out of its bundle:
a founder welcome video, then a voice-narrated, hands-on tour with a
single centred dark card, hand-drawn rings on the real control to press,
quiet sound cues, and a pace set by speech rather than timers.

- **Voice.** The script lives in `Resources/narration.json`, one line per
  id. `scripts/narration.py` renders every line with Kokoro (an open
  neural voice, on the CPU) into `Resources/narration/<voice>/<id>.m4a`,
  five voices bundled; `Narrator` (TakeoverVoice.swift) plays the clip
  for the chosen voice and calls back when it has been heard, and the
  guide advances on those callbacks, so nothing moves faster than it can
  be said. Settings → Voice → Visor's voice picks the voice (bundled, or
  any installed on the Mac) and lets you hear each one. Muted, lines run
  on a reading-speed timer.
- **No cut-outs.** The scrim is its own window ordered directly beneath
  the notch's, so the card, switcher and HUD draw over it as themselves.
  The overlay above owns clicks only inside the one card and the chrome
  (`TakeoverHostingView.hitTest`); everywhere else falls through.
- **Never stranded.** The stand-in takes over on any error, at any point
  in the real agent's turn — including a failure after the approval —
  and the tour tracks its own send directly rather than inferring it
  from the transcript.
- **Video.** If `Resources/intro.mp4` exists in the bundle the tour opens
  with it (`VideoIntro`, an `AVPlayerLayer`, thin accent progress bar) and
  begins when it ends; otherwise the mark rises out of the notch while the
  voice says hello. Record one — it is the single biggest lever.
- **One caption.** The mark and the current line, in one pill that has one
  home per moment (under the notch; beside the card). It turns into a
  check for two seconds when something lands.
- **One card.** The agent form and the goodbye, centred, no kicker, no
  dots, no glow. Progress is a 2pt accent line along the bottom.
- **Cues.** Synthesised `reveal`, `beat`, `success`, `stop` tones; voice
  and sound each have a switch at the top right, remembered.
- **No flash.** The scrim fades up over 1.1 s before anything else moves;
  the CRT sweep, scanlines and pixel field are gone.
- **Steps.** `intro → notch → agent → task → hud → drive → finale`, about
  three minutes with the voice on. The HUD beat opens the HUD on ⌃⌘M,
  holds it while the voice describes it, and folds it back.
- **Where things really are.** Controls the tour points at opt in with
  `.spotlight("allow")` / `.spotlight("stop")` (`Spotlight.swift`); the
  registry keeps their frames in screen coordinates, and the reticle locks
  onto the real chip, not a guess.
- **The sound, drawn.** The narrator meters its own audio (`VoiceMeter`)
  and the mark's halo and a soft light under the notch breathe with it;
  rings spread from the notch when a moment lands (`Sonar`); the reticle
  arrives from outside and settles with a spring, a readout above it and a
  leader line back to the caption; the finale's keys light in sequence.
