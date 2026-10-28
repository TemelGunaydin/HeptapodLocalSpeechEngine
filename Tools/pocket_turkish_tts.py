#!/usr/bin/env python3
"""Local CPU Pocket TTS Turkish, with a resident JSON-lines PCM streaming worker."""

from __future__ import annotations

import argparse
from array import array
import base64
import contextlib
import json
from pathlib import Path
import sys

MODEL_ID = "wite-tech/pocket-tts-turkish"
MODEL_REVISION = "fcbd37c74dc127be846face0ff36062e9a939f7b"
MODEL_DIRECTORY = Path.home() / "Library/Caches/HeptapodLocalSpeechEngine/Pocket-TTS-Turkish"
VOICES = tuple(f"{gender}_{index}" for gender in ("female", "male") for index in range(1, 4))


class TrailingSilenceBuffer:
    """Shorten only a completed utterance's quiet tail, preserving interior PCM.

    Eight PCM16 units are approximately -72 dBFS. Keep 150 ms beyond the last
    sample above that level so quiet word endings retain generous protection.
    Buffer at most 500 ms; a later word releases every held sample unchanged.
    """

    def __init__(self, sample_rate: int):
        self.keep_bytes = round(sample_rate * 0.150) * 2
        self.limit_bytes = round(sample_rate * 0.500) * 2
        self.pending = b""
        self.has_speech = False

    def push(self, pcm: bytes) -> bytes:
        samples = array("h")
        samples.frombytes(pcm)
        if sys.byteorder != "little":
            samples.byteswap()
        last_active = next((i for i in range(len(samples) - 1, -1, -1) if abs(samples[i]) > 8), -1)
        if last_active < 0 and not self.has_speech:
            # Leading silence and wholly quiet output are outside this filter's scope.
            return pcm
        if last_active >= 0:
            self.has_speech = True
            end = (last_active + 1) * 2
            output = self.pending + pcm[:end]
            self.pending = pcm[end:]
        else:
            output = b""
            self.pending += pcm
        excess = max(0, len(self.pending) - self.limit_bytes)
        output += self.pending[:excess]
        self.pending = self.pending[excess:]
        return output

    def finish(self) -> bytes:
        output = self.pending[:self.keep_bytes]
        self.pending = b""
        return output


def validate_request(text: str, language: str, voice: str) -> None:
    if not isinstance(language, str) or language.lower().replace("_", "-").split("-", 1)[0] != "tr":
        raise ValueError("Pocket TTS Turkish supports Turkish (tr) only")
    if not isinstance(text, str) or not text.strip():
        raise ValueError("text is required")
    if voice not in VOICES:
        raise ValueError(f"Unknown voice {voice!r}; choose from {', '.join(VOICES)}")


def load_model(directory: Path, *, offline: bool = False):
    from pocket_tts_turkish import TurkishTTS

    required = ["config.yaml", "model.safetensors", "tokenizer.model", *[f"voices/{v}.wav" for v in VOICES]]
    directory = directory.expanduser().resolve()
    if not all((directory / name).is_file() for name in required):
        if offline:
            raise FileNotFoundError("Pocket Turkish model is not cached. Run Tools/setup_pocket_tts.sh.")
        from huggingface_hub import snapshot_download

        snapshot_download(repo_id=MODEL_ID, revision=MODEL_REVISION, local_dir=directory, allow_patterns=required)
    # The upstream package normalizes Turkish numbers, abbreviations and sentence boundaries.
    with contextlib.redirect_stdout(sys.stderr):
        return TurkishTTS.from_pretrained(directory, device="cpu")


def stream_request(model, request: dict, *, default_voice: str):
    import numpy as np

    request_id = request["id"]
    text, language = request["text"], request.get("language", "tr")
    voice = request.get("voice_id") or default_voice
    validate_request(text, language, voice)
    emitted = False
    tail = TrailingSilenceBuffer(model.sample_rate)
    with contextlib.redirect_stdout(sys.stderr):
        chunks = model.stream(text.strip(), voice=voice, seed=42)
    try:
        while True:
            with contextlib.redirect_stdout(sys.stderr):
                chunk = next(chunks, None)
            if chunk is None:
                break
            audio = np.asarray(chunk).reshape(-1)
            if not np.isfinite(audio).all():
                raise ValueError("Model returned non-finite audio")
            if not audio.size:
                continue
            pcm = tail.push((np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes())
            if not pcm:
                continue
            emitted = True
            yield {"id": request_id, "event": "audio", "sample_rate": model.sample_rate,
                   "pcm16": base64.b64encode(pcm).decode("ascii")}
    finally:
        chunks.close()
    if pcm := tail.finish():
        emitted = True
        yield {"id": request_id, "event": "audio", "sample_rate": model.sample_rate,
               "pcm16": base64.b64encode(pcm).decode("ascii")}
    if not emitted:
        raise ValueError("Model returned no audio")
    yield {"id": request_id, "event": "done"}


def serve(model, *, voice: str) -> int:
    print(json.dumps({"ready": True, "sample_rate": model.sample_rate, "voices": list(VOICES)}), flush=True)
    for line in sys.stdin:
        if not line.strip():
            continue
        request = {}
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                request = {}
                raise ValueError("Expected a JSON object")
            for event in stream_request(model, request, default_voice=voice):
                print(json.dumps(event, ensure_ascii=False, separators=(",", ":")), flush=True)
        except Exception as exc:
            print(json.dumps({"id": request.get("id"), "event": "error", "error": str(exc)}), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", action="store_true")
    parser.add_argument("--model-dir", type=Path, default=MODEL_DIRECTORY)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--voice", choices=VOICES, default="female_2")
    parser.add_argument("--text")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.server and (not args.text or not args.output):
        parser.error("--text and --output are required outside server mode")
    model = load_model(args.model_dir, offline=args.offline)
    if args.server:
        # Encode the selected voice and warm the CPU kernels before declaring readiness.
        with contextlib.redirect_stdout(sys.stderr):
            model.generate("Hazır.", voice=args.voice, seed=42)
        return serve(model, voice=args.voice)
    import wave

    with wave.open(str(args.output), "wb") as output:
        output.setparams((1, 2, model.sample_rate, 0, "NONE", "not compressed"))
        for event in stream_request(model, {"id": "file", "text": args.text}, default_voice=args.voice):
            if event["event"] == "audio":
                output.writeframes(base64.b64decode(event["pcm16"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
