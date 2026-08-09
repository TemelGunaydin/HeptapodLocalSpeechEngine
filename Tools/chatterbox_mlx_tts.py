#!/usr/bin/env python3
"""Persistent MLX Chatterbox bridge for Heptapod quality speech output."""

from __future__ import annotations

import argparse
import contextlib
import json
import math
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
    parser.add_argument("--warmup", action="store_true", help="Warm the model before reporting ready.")
    parser.add_argument(
        "--trim-boundary-silence",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Trim excess leading and trailing silence from generated audio.",
    )
    parser.add_argument("--silence-threshold-db", type=float, default=-45.0)
    parser.add_argument("--leading-silence-ms", type=float, default=40.0)
    parser.add_argument("--trailing-silence-ms", type=float, default=120.0)
    parser.add_argument("--boundary-fade-ms", type=float, default=8.0)
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
        trim_boundary_silence=args.trim_boundary_silence,
        silence_threshold_db=args.silence_threshold_db,
        leading_silence_ms=args.leading_silence_ms,
        trailing_silence_ms=args.trailing_silence_ms,
        boundary_fade_ms=args.boundary_fade_ms,
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
    warmup_seconds = None
    if args.warmup:
        warmup_seconds = warm_up_model(
            runtime=runtime,
            model=model,
            language=normalize_language_code(args.language),
            voice_prompt=args.voice_prompt,
            exaggeration=args.exaggeration,
            cfg_weight=args.cfg_weight,
            temperature=args.temperature,
        )

    print(
        json.dumps(
            {
                "ready": True,
                "backend": "chatterbox-mlx",
                "sample_rate": int(model.sample_rate),
                "model_load_seconds": load_seconds,
                "warmup_seconds": warmup_seconds,
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
                trim_boundary_silence=args.trim_boundary_silence,
                silence_threshold_db=args.silence_threshold_db,
                leading_silence_ms=args.leading_silence_ms,
                trailing_silence_ms=args.trailing_silence_ms,
                boundary_fade_ms=args.boundary_fade_ms,
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
    trim_boundary_silence: bool,
    silence_threshold_db: float,
    leading_silence_ms: float,
    trailing_silence_ms: float,
    boundary_fade_ms: float,
) -> dict[str, object]:
    normalized_text = str(text or "").strip()
    if not normalized_text:
        raise ValueError("text is required")
    validate_language(language)
    if voice_prompt and not Path(str(voice_prompt)).expanduser().is_file():
        raise FileNotFoundError(f"voice prompt not found: {voice_prompt}")

    started_at = time.perf_counter()
    audio, sample_rate = generate_audio(
        runtime=runtime,
        model=model,
        text=normalized_text,
        language=language,
        voice_prompt=voice_prompt,
        exaggeration=exaggeration,
        cfg_weight=cfg_weight,
        temperature=temperature,
    )
    raw_sample_count = int(audio.size)
    trim_start = 0
    trim_end = raw_sample_count
    if trim_boundary_silence:
        trim_start, trim_end = boundary_trim_range(
            audio,
            sample_rate,
            threshold_db=silence_threshold_db,
            leading_padding_ms=leading_silence_ms,
            trailing_padding_ms=trailing_silence_ms,
        )
        audio = audio[trim_start:trim_end]
    boundary_fade_sample_count = apply_boundary_fade(
        audio,
        sample_rate,
        fade_ms=boundary_fade_ms,
    )

    output = output.expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    runtime["sf"].write(output, audio, sample_rate, subtype="PCM_16")

    elapsed = time.perf_counter() - started_at
    audio_seconds = float(audio.size) / sample_rate
    raw_audio_seconds = float(raw_sample_count) / sample_rate
    return {
        "sample_rate": sample_rate,
        "inference_seconds": elapsed,
        "audio_seconds": audio_seconds,
        "raw_audio_seconds": raw_audio_seconds,
        "trimmed_leading_seconds": float(trim_start) / sample_rate,
        "trimmed_trailing_seconds": float(raw_sample_count - trim_end) / sample_rate,
        "boundary_fade_seconds": float(boundary_fade_sample_count) / sample_rate,
        "rtf": elapsed / audio_seconds,
    }


def generate_audio(
    *,
    runtime,
    model,
    text: str,
    language: str,
    voice_prompt: str | None,
    exaggeration: float,
    cfg_weight: float,
    temperature: float,
):
    with contextlib.redirect_stdout(sys.stderr):
        results = list(
            model.generate(
                text=text,
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
    return audio, int(model.sample_rate)


def warm_up_model(
    *,
    runtime,
    model,
    language: str,
    voice_prompt: str | None,
    exaggeration: float,
    cfg_weight: float,
    temperature: float,
) -> float:
    started_at = time.perf_counter()
    generate_audio(
        runtime=runtime,
        model=model,
        text="Hazır." if language == "tr" else "Ready.",
        language=language,
        voice_prompt=voice_prompt,
        exaggeration=exaggeration,
        cfg_weight=cfg_weight,
        temperature=temperature,
    )
    return time.perf_counter() - started_at


def boundary_trim_range(
    samples,
    sample_rate: int,
    *,
    threshold_db: float = -45.0,
    leading_padding_ms: float = 40.0,
    trailing_padding_ms: float = 120.0,
) -> tuple[int, int]:
    sample_count = len(samples)
    if sample_count == 0 or sample_rate <= 0:
        return 0, sample_count

    frame_sample_count = max(1, int(round(sample_rate * 0.02)))
    threshold_power = math.pow(10.0, threshold_db / 10.0)
    first_active_sample = None
    last_active_sample = None

    for frame_start in range(0, sample_count, frame_sample_count):
        frame_end = min(sample_count, frame_start + frame_sample_count)
        power = sum(float(sample) * float(sample) for sample in samples[frame_start:frame_end])
        power /= frame_end - frame_start
        if power >= threshold_power:
            if first_active_sample is None:
                first_active_sample = frame_start
            last_active_sample = frame_end

    if first_active_sample is None or last_active_sample is None:
        return 0, sample_count

    leading_padding = int(round(sample_rate * max(0.0, leading_padding_ms) / 1_000.0))
    trailing_padding = int(round(sample_rate * max(0.0, trailing_padding_ms) / 1_000.0))
    return (
        max(0, first_active_sample - leading_padding),
        min(sample_count, last_active_sample + trailing_padding),
    )


def apply_boundary_fade(samples, sample_rate: int, *, fade_ms: float = 8.0) -> int:
    fade_sample_count = min(
        len(samples) // 2,
        int(round(sample_rate * max(0.0, fade_ms) / 1_000.0)),
    )
    if fade_sample_count <= 0:
        return 0

    denominator = max(1, fade_sample_count - 1)
    for index in range(fade_sample_count):
        gain = float(index) / denominator
        samples[index] *= gain
        samples[-(index + 1)] *= gain
    return fade_sample_count


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
