#!/usr/bin/env python3
"""Generate repeatable Chatterbox MLX prosody samples with one model load."""

from __future__ import annotations

import argparse
import json
import random
import time
from dataclasses import asdict, dataclass
from pathlib import Path

import chatterbox_mlx_tts


DEFAULT_TEXT = (
    "Bugün yerel canlı çeviriyi test ediyoruz. "
    "Çevrilmiş ses net, doğal ve akıcı duyulmalı."
)


@dataclass(frozen=True)
class QualityVariant:
    name: str
    exaggeration: float
    cfg_weight: float
    temperature: float = 0.8


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a Chatterbox prosody A/B matrix.")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--text", default=DEFAULT_TEXT)
    parser.add_argument("--language", default="tr")
    parser.add_argument("--voice-prompt", help="Optional clean 5-10 second native-language WAV.")
    parser.add_argument("--model", default=chatterbox_mlx_tts.DEFAULT_MODEL)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    output_dir = Path(args.output_dir).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    voice_prompt = str(Path(args.voice_prompt).expanduser()) if args.voice_prompt else None
    language = chatterbox_mlx_tts.normalize_language_code(args.language)
    chatterbox_mlx_tts.validate_language(language)

    runtime, model, load_seconds = chatterbox_mlx_tts.load_runtime(args.model)
    warmup_seconds = chatterbox_mlx_tts.warm_up_model(
        runtime=runtime,
        model=model,
        language=language,
        voice_prompt=voice_prompt,
        exaggeration=0.5,
        cfg_weight=0.5,
        temperature=0.8,
    )

    results = []
    for variant in quality_variants():
        set_seed(args.seed, runtime)
        output = output_dir / f"{variant.name}.wav"
        metrics = chatterbox_mlx_tts.synthesize_to_wav(
            runtime=runtime,
            model=model,
            text=args.text,
            language=language,
            output=output,
            voice_prompt=voice_prompt,
            exaggeration=variant.exaggeration,
            cfg_weight=variant.cfg_weight,
            temperature=variant.temperature,
            trim_boundary_silence=True,
            silence_threshold_db=-45.0,
            leading_silence_ms=40.0,
            trailing_silence_ms=120.0,
            boundary_fade_ms=8.0,
        )
        results.append({"file": output.name, **asdict(variant), **metrics})

    manifest = {
        "created_at_epoch": time.time(),
        "model": args.model,
        "model_load_seconds": load_seconds,
        "warmup_seconds": warmup_seconds,
        "language": language,
        "text": args.text,
        "voice_prompt": voice_prompt,
        "seed": args.seed,
        "results": results,
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(results)} samples and {manifest_path}")
    return 0


def quality_variants() -> tuple[QualityVariant, ...]:
    return (
        QualityVariant("flat-e010-cfg050", exaggeration=0.1, cfg_weight=0.5),
        QualityVariant("neutral-e050-cfg050", exaggeration=0.5, cfg_weight=0.5),
        QualityVariant("deliberate-e050-cfg030", exaggeration=0.5, cfg_weight=0.3),
        QualityVariant("expressive-e070-cfg030", exaggeration=0.7, cfg_weight=0.3),
    )


def set_seed(seed: int, runtime) -> None:
    import mlx.core as mx

    random.seed(seed)
    runtime["np"].random.seed(seed)
    mx.random.seed(seed)


if __name__ == "__main__":
    raise SystemExit(main())
