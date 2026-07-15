#!/usr/bin/env python3
"""Persistent MLX Chatterbox bridge for Heptapod quality speech output."""

from __future__ import annotations

import argparse
import contextlib
import json
import sys
import time
from pathlib import Path


DEFAULT_MODEL = "mlx-community/chatterbox-fp16"
SUPPORTED_LANGUAGE_CODES = {
    "ar",
    "cs",
    "de",
    "en",
    "es",
    "fr",
    "hu",
    "it",
    "ja",
    "ko",
    "nl",
    "pl",
    "pt",
    "ru",
    "tr",
    "zh",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate speech with Chatterbox MLX.")
    parser.add_argument("--server", action="store_true", help="Run a persistent JSON-lines worker.")
    parser.add_argument("--text", help="Text to synthesize.")
    parser.add_argument("--language", default="tr", help="BCP-47-ish output language code.")
    parser.add_argument("--output", help="PCM16 WAV output path.")
    parser.add_argument("--voice-prompt", help="Optional 5-10 second reference audio.")
    parser.add_argument("--voice-id", help="Reserved for future named voices; currently ignored.")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="MLX Chatterbox model repository or path.")
    parser.add_argument("--device", choices=["auto", "cpu", "mps", "cuda"], default="auto")
    parser.add_argument("--multilingual", action="store_true", help="Accepted for bridge compatibility.")
    parser.add_argument("--exaggeration", type=float, default=0.1)
    parser.add_argument("--cfg-weight", type=float, default=0.5)
    parser.add_argument("--temperature", type=float, default=0.8)
    args = parser.parse_args()

    if not args.server and (not args.text or not args.output):
        parser.error("--text and --output are required unless --server is used")
    if args.device not in {"auto", "mps"}:
        parser.error("Chatterbox MLX runs on Apple Silicon Metal; use --device auto or mps")

    runtime, model, load_seconds = load_runtime(args.model)
    language = normalize_language_code(args.language)
    validate_language(language)

    if args.server:
        return run_server(args, runtime=runtime, model=model, load_seconds=load_seconds)

    metrics = synthesize_to_wav(
        runtime=runtime,
        model=model,
        text=args.text,
        language=language,
        output=Path(args.output),
        voice_prompt=args.voice_prompt,
        exaggeration=args.exaggeration,
        cfg_weight=args.cfg_weight,
        temperature=args.temperature,
    )
    print(json.dumps({"model_load_seconds": load_seconds, **metrics}, separators=(",", ":")))
    return 0


def load_runtime(model_name: str):
    try:
        import numpy as np
        import soundfile as sf
        from mlx_audio.tts.utils import load_model
    except ImportError as exc:
        print("Missing Chatterbox MLX dependencies. Run Tools/setup_chatterbox_mlx.sh.", file=sys.stderr)
        raise exc

    started_at = time.perf_counter()
    # Model loading prints progress to stdout. Keep stdout reserved for JSONL.
    with contextlib.redirect_stdout(sys.stderr):
        model = load_model(model_name)
    return {"np": np, "sf": sf}, model, time.perf_counter() - started_at


def run_server(args, *, runtime, model, load_seconds: float) -> int:
    print(
        json.dumps(
            {
                "ready": True,
                "backend": "chatterbox-mlx",
                "sample_rate": int(model.sample_rate),
                "model_load_seconds": load_seconds,
            },
            separators=(",", ":"),
        ),
        flush=True,
    )

    for line in sys.stdin:
        if not line.strip():
            continue
        request: dict[str, object] = {}
        try:
            request = json.loads(line)
            output = Path(str(request["output"]))
            metrics = synthesize_to_wav(
                runtime=runtime,
                model=model,
                text=str(request["text"]),
                language=normalize_language_code(str(request.get("language") or args.language)),
                output=output,
                voice_prompt=request.get("voice_prompt") or args.voice_prompt,
                exaggeration=args.exaggeration,
                cfg_weight=args.cfg_weight,
                temperature=args.temperature,
            )
            print(
                json.dumps(
                    {
                        "id": request.get("id"),
                        "ok": True,
                        "output": str(output),
                        **metrics,
                    },
                    separators=(",", ":"),
                ),
                flush=True,
            )
        except Exception as exc:  # noqa: BLE001 - keep the worker alive after request failures.
            print(
                json.dumps(
                    {"id": request.get("id"), "ok": False, "error": str(exc)},
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
                flush=True,
            )
    return 0


def synthesize_to_wav(
    *,
    runtime,
    model,
    text: str,
    language: str,
    output: Path,
    voice_prompt: str | None,
    exaggeration: float,
    cfg_weight: float,
    temperature: float,
) -> dict[str, object]:
    normalized_text = str(text or "").strip()
    if not normalized_text:
        raise ValueError("text is required")
    validate_language(language)
    if voice_prompt and not Path(str(voice_prompt)).expanduser().is_file():
        raise FileNotFoundError(f"voice prompt not found: {voice_prompt}")

    started_at = time.perf_counter()
    with contextlib.redirect_stdout(sys.stderr):
        results = list(
            model.generate(
                text=normalized_text,
                lang_code=language,
                ref_audio=str(voice_prompt) if voice_prompt else None,
                exaggeration=min(max(float(exaggeration), 0.0), 1.0),
                cfg_weight=max(float(cfg_weight), 0.0),
                temperature=max(float(temperature), 0.01),
                verbose=False,
            )
        )
    if not results:
        raise RuntimeError("Chatterbox MLX produced no audio")

    np = runtime["np"]
    audio = np.concatenate([np.asarray(result.audio).reshape(-1) for result in results])
    if audio.size == 0:
        raise RuntimeError("Chatterbox MLX produced an empty waveform")
    sample_rate = int(model.sample_rate)
    output = output.expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    runtime["sf"].write(output, audio, sample_rate, subtype="PCM_16")

    elapsed = time.perf_counter() - started_at
    audio_seconds = float(audio.size) / sample_rate
    return {
        "sample_rate": sample_rate,
        "inference_seconds": elapsed,
        "audio_seconds": audio_seconds,
        "rtf": elapsed / audio_seconds,
    }


def normalize_language_code(language: str) -> str:
    code = language.strip().lower().replace("_", "-")
    return (code or "en").split("-", maxsplit=1)[0]


def validate_language(language: str) -> None:
    if language not in SUPPORTED_LANGUAGE_CODES:
        raise ValueError(
            f"Chatterbox MLX does not list language '{language}'. "
            f"Supported: {', '.join(sorted(SUPPORTED_LANGUAGE_CODES))}"
        )


if __name__ == "__main__":
    raise SystemExit(main())
