#!/usr/bin/env python3
"""Render the introduction's narration with a neural voice.

Reads app/Sources/Visor/Resources/narration.json (id → line) and writes
app/Sources/Visor/Resources/narration/<voice>/<id>.m4a for each bundled
voice, using Kokoro (open weights, runs on the CPU) via kokoro-onnx, then
afconvert for AAC. The app plays these clips instead of asking the Mac to
read the text — a real voice, no key, no latency.

    python3 -m venv .venv && .venv/bin/pip install kokoro-onnx soundfile
    curl -L -o kokoro-v1.0.onnx  https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
    curl -L -o voices-v1.0.bin   https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
    .venv/bin/python scripts/narration.py --models <dir with the two files> [--voices heart,george]

Re-run after editing narration.json; only changed or missing clips are
rendered unless --force.
"""
import argparse, json, os, subprocess, sys, tempfile

VOICES = {          # folder → Kokoro voice
    "heart":   "af_heart",
    "sky":     "af_sky",
    "george":  "bm_george",
    "michael": "am_michael",
    "emma":    "bf_emma",
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--voices", default=",".join(VOICES))
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--speed", type=float, default=0.95)
    args = ap.parse_args()

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "Sources", "Visor", "Resources")
    with open(os.path.join(root, "narration.json")) as f:
        script = json.load(f)

    from kokoro_onnx import Kokoro
    import soundfile as sf
    k = Kokoro(os.path.join(args.models, "kokoro-v1.0.onnx"), os.path.join(args.models, "voices-v1.0.bin"))

    stamp = os.path.getmtime(os.path.join(root, "narration.json"))
    for folder in args.voices.split(","):
        voice = VOICES[folder]
        out = os.path.join(root, "narration", folder)
        os.makedirs(out, exist_ok=True)
        for id_, text in script.items():
            m4a = os.path.join(out, f"{id_}.m4a")
            if not args.force and os.path.exists(m4a) and os.path.getmtime(m4a) >= stamp:
                continue
            samples, sr = k.create(text, voice=voice, speed=args.speed, lang="en-gb" if voice.startswith("b") else "en-us")
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                sf.write(tmp.name, samples, sr)
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", tmp.name, m4a],
                           check=True, stdout=subprocess.DEVNULL)
            os.unlink(tmp.name)
            print(f"{folder}/{id_}  {len(samples)/sr:.1f}s", flush=True)

if __name__ == "__main__":
    main()
