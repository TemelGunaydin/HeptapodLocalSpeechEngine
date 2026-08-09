#!/usr/bin/env python3
"""Persistent MLX bridge for local TranslateGemma text translation."""

from __future__ import annotations

import argparse
import contextlib
import json
import sys
import time
from dataclasses import dataclass
from typing import Any, Callable


DEFAULT_MODEL = "mlx-community/translategemma-4b-it-4bit"


@dataclass(frozen=True)
class TranslationRuntime:
    model: Any
    tokenizer: Any
    generate: Callable[..., str]
    sampler: Any


def main() -> int:
    parser = argparse.ArgumentParser(description="Translate text with TranslateGemma on MLX.")
    parser.add_argument("--server", action="store_true", help="Run a persistent JSON-lines worker.")
    parser.add_argument("--text", help="Text to translate in one-shot mode.")
    parser.add_argument("--source-language", default="en", help="Source language code.")
    parser.add_argument("--target-language", default="tr", help="Target language code.")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="MLX model repository or path.")
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--warmup", action="store_true", help="Warm Metal inference before reporting ready.")
    args = parser.parse_args()

    if not args.server and not args.text:
        parser.error("--text is required unless --server is used")
    if args.max_tokens <= 0:
        parser.error("--max-tokens must be positive")

    runtime, load_seconds = load_runtime(args.model)
    if args.warmup:
        translate_text(
            runtime,
            "Local translation is ready.",
            source_language="en",
            target_language=args.target_language,
            max_tokens=32,
        )

    if args.server:
        return run_server(runtime, args.model, load_seconds, args.max_tokens)

    started_at = time.perf_counter()
    translation = translate_text(
        runtime,
        args.text,
        source_language=args.source_language,
        target_language=args.target_language,
        max_tokens=args.max_tokens,
    )
    print(
        json.dumps(
            {
                "translation": translation,
                "model": args.model,
                "model_load_seconds": load_seconds,
                "generation_seconds": time.perf_counter() - started_at,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
    )
    return 0


def load_runtime(model_name: str) -> tuple[TranslationRuntime, float]:
    try:
        from mlx_lm import generate, load
        from mlx_lm.sample_utils import make_sampler
    except ImportError as exc:
        print(
            "Missing TranslateGemma MLX dependencies. Run Tools/setup_translategemma_mlx.sh.",
            file=sys.stderr,
        )
        raise exc

    started_at = time.perf_counter()
    with contextlib.redirect_stdout(sys.stderr):
        model, tokenizer = load(model_name)
    tokenizer.add_eos_token("<end_of_turn>")
    runtime = TranslationRuntime(
        model=model,
        tokenizer=tokenizer,
        generate=generate,
        sampler=make_sampler(temp=0.0),
    )
    return runtime, time.perf_counter() - started_at


def translate_text(
    runtime: TranslationRuntime,
    text: str,
    *,
    source_language: str,
    target_language: str,
    max_tokens: int,
) -> str:
    source_text = text.strip()
    if not source_text:
        raise ValueError("source text is empty")

    source_code = normalize_language_code(source_language)
    target_code = normalize_language_code(target_language)
    messages = [
        {
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "source_lang_code": source_code,
                    "target_lang_code": target_code,
                    "text": source_text,
                }
            ],
        }
    ]
    prompt = runtime.tokenizer.apply_chat_template(
        messages,
        add_generation_prompt=True,
        tokenize=False,
    )
    with contextlib.redirect_stdout(sys.stderr):
        result = runtime.generate(
            runtime.model,
            runtime.tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=runtime.sampler,
            verbose=False,
        )
    translation = result.strip()
    if not translation:
        raise RuntimeError("TranslateGemma returned an empty translation")
    return translation


def run_server(
    runtime: TranslationRuntime,
    model_name: str,
    load_seconds: float,
    default_max_tokens: int,
) -> int:
    write_json(
        {
            "ready": True,
            "model": model_name,
            "model_load_seconds": load_seconds,
        }
    )

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        request_id: str | None = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            started_at = time.perf_counter()
            translation = translate_text(
                runtime,
                request["text"],
                source_language=request["source_language"],
                target_language=request["target_language"],
                max_tokens=int(request.get("max_tokens", default_max_tokens)),
            )
            write_json(
                {
                    "id": request_id,
                    "ok": True,
                    "translation": translation,
                    "generation_seconds": time.perf_counter() - started_at,
                }
            )
        except Exception as exc:  # Keep the persistent worker alive after a bad request.
            write_json(
                {
                    "id": request_id,
                    "ok": False,
                    "error": f"{type(exc).__name__}: {exc}",
                }
            )
    return 0


def normalize_language_code(language: str) -> str:
    code = language.strip().replace("_", "-")
    if not code:
        raise ValueError("language code is empty")
    parts = code.split("-")
    parts[0] = parts[0].lower()
    if len(parts) == 2 and len(parts[1]) == 2:
        parts[1] = parts[1].upper()
    return "-".join(parts)


def write_json(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
