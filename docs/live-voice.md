# Live conversation

Talk to any agent. The waveform beside the agent's name — in the notch
card's shoulder and in the HUD's header — opens a **GPT-Live** session
(`gpt-live-1`, OpenAI's full-duplex voice model) with Visor as its
backend.

## How it fits together

```
you ──audio──▶ GPT-Live ──delegation──▶ Visor ──text──▶ selected agent (its own model)
you ◀──audio── GPT-Live ◀──commentary── Visor ◀──reply── selected agent
```

- `LiveSession` (LiveVoice.swift) holds one WebSocket to
  `wss://api.openai.com/v1/live/sessions`, starts the session with
  `delegation: {type: "client"}`, streams the microphone as PCM16 at
  24 kHz and plays the voice's PCM16 back through `AVAudioEngine`.
- The voice's instructions make it the *voice of the agent*: it never
  answers itself, it delegates and relays. Small talk it may take.
- On `session.delegation.created` the text heard since the last turn goes
  to the selected agent exactly as if typed: it lands in the transcript,
  the reply streams. Each finished paragraph is handed back with
  `session.commentary.append` on the open delegation so the voice starts
  talking before the agent is done; the rest follows when the reply ends.
- A tool approval turns into a question ("it wants to run …, allow it?");
  the next thing you say is matched against yes/no words and answered
  through the same `approvePending`/`denyPending` the chips use.
- Markdown is made sayable first (`LiveSession.speakable`): fenced code
  becomes "(code: first line …)", tables become sentences, emphasis and
  links are stripped. Appends are cut at ~1400 characters.
- Talking while it speaks drops the queued audio (`bargeIn`, Settings).
- The key is the OpenAI voice key (Settings → Voice), the same one
  dictation uses. Voice: Settings → Voice → Live conversation.

## What isn't there yet

- Push-to-talk. The session is open-mic with a mute; the dictation
  trigger key is still dictation's.
- Verbatim relay. GPT-Live paraphrases what the backend returns; numbers
  and names are asked to be kept exact in the instructions, and the full
  reply is always in the transcript.
- Verified end to end: written against the Live API documentation on its
  release day (2026-09-10); the event shapes for `session.delegation.created`
  and errors are handled defensively.
