#!/usr/bin/env python3
"""Exercise the shipped native speech-to-Qwen pipeline, plus silence rejection."""
import json
import pathlib
import subprocess
import tempfile
import wave

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "dist/Local Wispr.app/Contents/MacOS/LocalWispr"
SAMPLE = ROOT / ".build/vendor/whisper.cpp/samples/jfk.wav"

result = subprocess.run([str(APP), "--self-test", str(SAMPLE)], capture_output=True, text=True, timeout=240)
assert result.returncode == 0, result.stderr
data = json.loads(result.stdout)
raw = data["transcript"].lower()
cleaned = data["cleaned"].lower()
assert data["ok"] is True
assert data["timedWords"] == 0 and data["experimentalFormatting"] is False
assert "ask not what your country can do for you" in raw, raw
assert "ask not what your country can do for you" in cleaned, cleaned
assert "what you can do for your country" in cleaned, cleaned
assert "<think>" not in cleaned and "here is" not in cleaned, cleaned
print(f"PASS: local speech → local Qwen ({data['totalSeconds']:.1f}s for the public sample)")

with tempfile.TemporaryDirectory(prefix="local-wispr-test-") as directory:
    silent = pathlib.Path(directory) / "silence.wav"
    with wave.open(str(silent), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(b"\0\0" * 32000)
    rejected = subprocess.run([str(APP), "--self-test", str(silent)], capture_output=True, text=True, timeout=30)
    assert rejected.returncode != 0, "Silence should not produce a transcript."
    assert "No speech was detected" in rejected.stderr, rejected.stderr
print("PASS: silence rejected without asking Qwen to invent text")

commands = "Start list bold on cucumbers bold off next item italic on carrots italic off next item caps on apples caps off end list"
formatted = subprocess.run([str(APP), "--format-text", commands], capture_output=True, text=True, timeout=180)
assert formatted.returncode == 0, formatted.stderr
lines = json.loads(formatted.stdout)["cleaned"].splitlines()
assert len(lines) == 3 and all(line.startswith("- ") for line in lines), lines
assert lines[0].lower().startswith("- **cucumbers**"), lines
assert lines[1].lower().startswith("- *carrots*"), lines
assert lines[2].startswith("- APPLES"), lines
assert "bold on" not in " ".join(lines).lower(), lines
print("PASS: local Qwen preserves list items; Markdown styles survive cleanup")

experimental = subprocess.run([str(APP), "--self-test", str(SAMPLE), "--experimental-formatting"],
                              capture_output=True, text=True, timeout=240)
assert experimental.returncode == 0, experimental.stderr
data = json.loads(experimental.stdout)
assert data["experimentalFormatting"] is True and data["timedWords"] >= 15, data
assert "what your country can do for you" in data["cleaned"].replace("*", "").lower(), data
print(f"PASS: optional word timing → acoustic analysis → Qwen ({data['timedWords']} timed segments)")
