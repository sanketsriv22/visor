# Dictation speed

## Where the time went

The old path was serial and nothing in it started until key-up:

```
record to AAC file → (key-up) → DNS/TLS → upload whole file → transcribe whole file → cleanup round-trip → insert
```

The code's own measurement: 96 s of speech took 3.7 s, 7 s took 2.8 s.
Most of the wait was fixed cost paid after you stopped talking, plus an
upload that scaled with length.

## What Wispr Flow does

Streams audio to the recogniser *while you speak*, so recognition keeps
pace with the words and key-up only has to finish the tail. Their
enhancement step is a small fine-tuned model on dedicated inference,
inside a ~700 ms p99 budget end to end. The insight is not a faster
model; it is that the work overlaps the speaking.

## What Visor does now

`StreamingTranscriber` opens `wss://api.openai.com/v1/realtime?intent=transcription`
the moment recording starts, sends `session.update` with
`type: "transcription"`, PCM16 at 24 kHz, near-field noise reduction,
`gpt-4o-mini-transcribe` by default ($0.003/min; the full `gpt-4o-transcribe` is $0.006 and a switch in Settings; the file path's `gpt-transcribe` is $0.0045 but cannot do turn detection), and **server VAD with a 900 ms silence** — long
enough that a breath mid-sentence doesn't end a segment. The microphone
is streamed in 100 ms pieces. Each pause closes a segment
(`input_audio_buffer.committed` → an item) that the service transcribes
*while you keep talking*; deltas and `completed` events are keyed by
item id and stitched in order, joined with a space. Key-up commits only
the phrase in flight and waits for the open items to finish. A
five-second guard hands over whatever has arrived if a final never does.

The first version of this had turn detection off, on the theory that
we'd end the turn at key-up. With it off the service transcribes nothing
until the commit, so every second of speech was still processed after
key-up — the voice log showed the wait scaling with length exactly as
the upload had (30 s for a half-hour dictation). The log now records
which path ran (`path`) and why the stream fell back (`note`).

`AVAudioRecorder` still writes the AAC file alongside, for metering and
as the fallback: any stream failure — no session, dropped socket, error
event — uploads the file exactly as before. Both paths land in one
`deliver` that runs cleanup (only when the text has no punctuation),
writes the voice log, and hands the text on.

Fidelity: same model family; the stream sends raw 24 kHz PCM where the
file path re-encoded to 16 kHz AAC, so if anything it is slightly better.

## Measuring

Every dictation logs `transcribeSeconds` — for the stream, the wait
after key-up; for the upload, the wait after the file was ready — to
`voice-log.jsonl`, shown in Settings → Voice → Voice log. Compare the two
paths with the Speed switch in Settings → Voice.

## Invariants (tested in ListeningTests)

- **One shape per session.** `NotchVisuals.Shape` — whether there is a
  left pill, and how far the pills hang — is snapshotted by
  `beginSession()` when listening starts and held until the pills are
  gone. The window frame (`NotchController.listeningFrame`), the sticky
  view's pills and the strip under the notch all read `active`. Changing
  the visual mid-session takes effect next session. The 2026-09-15 bug
  was the frame reading one visual and the pills another.
- **The microphone opens on key-down; the pill shows on the hold.**
  `PushToTalk.pressed()` calls `onArm` at once (capture, no UI), then
  `onHoldStart` at 180 ms (the pill). Release after a hold transcribes; a
  lone tap cancels the armed capture silently (no UI ever showed, so no
  flash); a double-tap toggles on. A tap must be nothing: modifier keys
  are tapped by accident all day, and a tap that started a recording left
  the mic light on.
- **The meter holds the last buffer's peak.** Buffers arrive at ~20 Hz,
  the meter samples at 50; reading silence between them collapsed the
  noise floor and lit the meter on room noise.
- **Every visual fills its grid.** All thirteen return 20×10 values in
  0…1 for both sides at any time; fire is hotter at the bottom.
- The lab's `notch-listening` scene draws the collapsed notch for a
  two-sided and a one-sided visual, recording and transcribing, with the
  computed window frame outlined in red so a mismatch is visible.

## The empty-buffer race (found 2026-09-15 with `--probe-transcription`)

When you stop talking and release the key in the same moment, the
service's voice detector has just committed your last phrase itself, so
our `input_audio_buffer.commit` is refused with "buffer too small …
0.00ms". That refusal is not "nothing left": the detector's item and its
transcript are on their way. Closing the socket on the refusal — which
is what lost transcripts — is gone.

The socket is ordered, and that decides when the final is declared with
no grace at all (2026-09-16; the 700 ms grace plus a 1.5 s wait on the
refusal had put 1.2–2.8 s between key-up and delivery). Key-up sends
one commit, and the service answers it in exactly one of two ways:

- `input_audio_buffer.committed` with no `speech_stopped` before it —
  the detector's own commits always follow a `speech_stopped`. This is
  our segment, and it is the last one: the buffer is now empty and no
  more audio is sent.
- "buffer too small" — the detector took the last phrase itself, and
  since it sent that segment's `committed` before this error, the
  segment is already open here.

Either way, once the answer has arrived every segment the service will
ever open is known, and the transcript is final the moment the last of
them completes. A `speech_stopped` after the answer is ignored. The 6 s
cap remains as the backstop.

A double-tap no longer rebuilds the microphone and session: a lone tap's
cancel waits out the double-tap window, so the second tap carries on
with what the first one armed instead of paying the ~170 ms mic restart
and a fresh socket.

`Visor --probe-transcription <eager|wait> <model>` replays the session
against the real service with the app's key and writes every server
event to `~/Library/Logs/Visor/probe.log`; `dictation.log` beside it
traces every real dictation.
