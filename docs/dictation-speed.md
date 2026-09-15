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
`gpt-transcribe`, and **no turn detection** (we end the turn ourselves on
key-up, so a pause never cuts a sentence). The microphone is streamed in
100 ms pieces; `conversation.item.input_audio_transcription.delta`
events build the text as you speak and show faintly in the composer.
Key-up sends one `input_audio_buffer.commit`; the `completed` event is
the transcript. A six-second guard hands over whatever has arrived if
the final never does.

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
