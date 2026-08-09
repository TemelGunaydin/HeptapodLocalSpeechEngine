#!/usr/bin/env python3
"""Benchmark bounded-context Qwen post-editing on translation JSON output."""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import statistics
import sys
import time
from pathlib import Path
from typing import Any


DEFAULT_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
PROMPT_VERSION = "minimal-edit-v2"
SYSTEM_PROMPT = """You are a minimal-change translation proofreader for spoken Turkish.
Your default action is to copy the draft exactly. Change it only when it contains a clear grammatical error, unnatural word order, or a definite terminology mistranslation confirmed by the English source.
Make the smallest possible edit. Never rewrite an accurate sentence merely to improve style or choose synonyms.
Never change the subject, object, voice, tense, modality, certainty, singular/plural meaning, names, numbers, conditions, or quotation meaning.
Do not summarize, explain, add information, or omit information.
Keep terminology consistent with accepted context. In this software domain prefer: first run = ilk çalıştırma; persistent worker = kalıcı worker; stable transcript prefix = kararlı transkript öneki; speech synthesis = ses sentezi; segment = segment; trading quality for latency = gecikme uğruna kaliteden ödün vermek.
Before answering, verify the Turkish against the English source. If uncertain, return the draft unchanged.
Return only the final Turkish translation, with no label, quotation marks, notes, or explanation."""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Translation benchmark JSON to post-edit.")
    parser.add_argument("--output", required=True, help="Output report JSON.")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--context-limit", type=int, default=2)
    parser.add_argument("--max-tokens", type=int, default=160)
    parser.add_argument("--no-warmup", action="store_true")
    args = parser.parse_args()

    if not 0 <= args.context_limit <= 8:
        parser.error("--context-limit must be from 0 through 8")
    if args.max_tokens <= 0:
        parser.error("--max-tokens must be positive")

    input_path = Path(args.input).expanduser()
    output_path = Path(args.output).expanduser()
    report = json.loads(input_path.read_text(encoding="utf-8"))
    results = report.get("results")
    if not isinstance(results, list) or not results:
        raise ValueError("input report has no translation results")

    runtime, load_seconds = load_runtime(args.model)
    warmup_seconds = None
    if not args.no_warmup:
        warmup_started = time.perf_counter()
        generate_post_edit(
            runtime,
            source="Local translation is ready.",
            draft="Yerel çeviri hazır.",
            context=[],
            max_tokens=32,
        )
        warmup_seconds = time.perf_counter() - warmup_started

    context: list[tuple[str, str]] = []
    post_edit_seconds: list[float] = []
    edited_results: list[dict[str, Any]] = []
    for item in results:
        source = required_string(item, "source")
        draft = required_string(item, "translation")
        started = time.perf_counter()
        raw_output = generate_post_edit(
            runtime,
            source=source,
            draft=draft,
            context=context[-args.context_limit :] if args.context_limit else [],
            max_tokens=args.max_tokens,
        )
        elapsed = time.perf_counter() - started
        translation = normalize_output(raw_output)
        if not translation:
            raise RuntimeError(f"empty post-edit for {item.get('id', '<unknown>')}")

        post_edit_seconds.append(elapsed)
        context.append((source, translation))
        edited_results.append(
            {
                **item,
                "draft_translation": draft,
                "translation": translation,
                "raw_post_edit": raw_output,
                "post_edit_seconds": elapsed,
            }
        )

    output_report = {
        **report,
        "post_edit_backend": "qwen3-4b-instruct-2507-4bit",
        "post_edit_model": args.model,
        "post_edit_prompt_version": PROMPT_VERSION,
        "post_edit_context_limit": args.context_limit,
        "post_edit_model_load_seconds": load_seconds,
        "post_edit_warmup_seconds": warmup_seconds,
        "average_post_edit_seconds": statistics.fmean(post_edit_seconds),
        "median_post_edit_seconds": statistics.median(post_edit_seconds),
        "p95_post_edit_seconds": percentile(post_edit_seconds, 0.95),
        "maximum_post_edit_seconds": max(post_edit_seconds),
        "results": edited_results,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(output_report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(edited_results)} post-edits to {output_path}")
    return 0


def load_runtime(model_name: str) -> tuple[dict[str, Any], float]:
    try:
        from mlx_lm import generate, load
        from mlx_lm.sample_utils import make_sampler
    except ImportError as exc:
        print("Missing MLX LM. Run Tools/setup_qwen_postedit_mlx.sh.", file=sys.stderr)
        raise exc

    started = time.perf_counter()
    with contextlib.redirect_stdout(sys.stderr):
        model, tokenizer = load(model_name)
    return {
        "model": model,
        "tokenizer": tokenizer,
        "generate": generate,
        "sampler": make_sampler(temp=0.0),
    }, time.perf_counter() - started


def generate_post_edit(
    runtime: dict[str, Any],
    *,
    source: str,
    draft: str,
    context: list[tuple[str, str]],
    max_tokens: int,
) -> str:
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": build_user_prompt(source=source, draft=draft, context=context),
        },
    ]
    prompt = runtime["tokenizer"].apply_chat_template(
        messages,
        add_generation_prompt=True,
        tokenize=False,
    )
    with contextlib.redirect_stdout(sys.stderr):
        result = runtime["generate"](
            runtime["model"],
            runtime["tokenizer"],
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=runtime["sampler"],
            verbose=False,
        )
    return result.strip()


def build_user_prompt(
    *,
    source: str,
    draft: str,
    context: list[tuple[str, str]],
) -> str:
    if context:
        context_text = "\n".join(
            f"Pair {index} source: {item_source}\n"
            f"Pair {index} accepted Turkish: {item_translation}"
            for index, (item_source, item_translation) in enumerate(context, start=1)
        )
    else:
        context_text = "None"

    return f"""Previous accepted sentence pairs:
{context_text}

Current English source:
{source}

Draft Turkish translation:
{draft}

Return the corrected Turkish translation. If the draft is already accurate and natural, return it unchanged."""


def normalize_output(output: str) -> str:
    result = output.strip()
    if len(result) >= 2 and result[0] == result[-1] and result[0] in {'"', "'"}:
        result = result[1:-1].strip()
    for prefix in ("Düzeltilmiş çeviri:", "Çeviri:", "Translation:"):
        if result.casefold().startswith(prefix.casefold()):
            result = result[len(prefix) :].strip()
            break
    return result


def required_string(item: dict[str, Any], key: str) -> str:
    value = item.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"result is missing non-empty {key}")
    return value.strip()


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * quantile) - 1))
    return ordered[index]


if __name__ == "__main__":
    raise SystemExit(main())
