#!/usr/bin/env python3
"""Local Chatterbox TTS bridge for Heptapod.

Install dependencies in your chosen Python environment:

    pip install chatterbox-tts torchaudio

This script intentionally imports torch/chatterbox only after argument parsing so
`--help` works even before the optional TTS environment is installed.
"""

from __future__ import annotations

import argparse
import inspect
import json
import sys
from pathlib import Path


MULTILINGUAL_LANGUAGE_CODES = {
    "ar",
    "da",
    "de",
    "el",
    "en",
    "es",
    "fi",
    "fr",
    "he",
    "hi",
    "it",
    "ja",
    "ko",
    "ms",
    "nl",
    "no",
    "pl",
    "pt",
    "ru",
    "sv",
    "sw",
    "tr",
    "zh",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a WAV file with Chatterbox TTS.")
    parser.add_argument("--text", help="Text to synthesize.")
    parser.add_argument("--language", default="en", help="BCP-47-ish target language code, such as en, tr, es, fr.")
    parser.add_argument("--output", help="Output WAV path.")
    parser.add_argument("--voice-prompt", help="Optional 5-10 second reference WAV for voice cloning.")
    parser.add_argument("--voice-id", help="Reserved for future named-voice selection; currently ignored.")
    parser.add_argument("--device", choices=["auto", "cpu", "mps", "cuda"], default="auto", help="Torch device.")
    parser.add_argument("--multilingual", action="store_true", help="Force ChatterboxMultilingualTTS.")
    parser.add_argument("--server", action="store_true", help="Run a JSON-lines synthesis worker on stdin/stdout.")
    parser.add_argument("--t3-model", help="Optional multilingual T3 model, for example v2 or v3.")
    args = parser.parse_args()

    if not args.server and (not args.text or not args.output):
        parser.error("--text and --output are required unless --server is used")

    if args.output:
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)

    try:
        runtime = load_runtime()
    except ImportError as exc:
        print(
            "Missing Python dependency. Install with: pip install chatterbox-tts torchaudio",
            file=sys.stderr,
        )
        raise exc

    language = normalize_language_code(args.language)
    device = choose_device(args.device, runtime["torch"])
    use_multilingual = args.multilingual or language != "en"
    patch_missing_perth_watermarker(runtime["perth"])
    model = load_model(
        runtime=runtime,
        language=language,
        device=device,
        use_multilingual=use_multilingual,
        t3_model=args.t3_model,
    )

    if args.server:
        return run_server(args, runtime=runtime, model=model, initial_language=language, use_multilingual=use_multilingual)

    wav = generate_audio(
        model=model,
        text=args.text,
        language=language,
        voice_prompt=args.voice_prompt,
        use_multilingual=use_multilingual,
    )
    runtime["torchaudio"].save(str(output), wav, model.sr)
    print(f"Wrote {output} at {model.sr} Hz")
    return 0


def load_runtime():
    import torch
    import torchaudio as ta
    import perth

    return {
        "torch": torch,
        "torchaudio": ta,
        "perth": perth,
    }


def load_model(*, runtime, language: str, device: str, use_multilingual: bool, t3_model: str | None):
    if use_multilingual:
        if language not in MULTILINGUAL_LANGUAGE_CODES:
            raise ValueError(
                f"Chatterbox multilingual does not list language '{language}'. "
                f"Supported: {', '.join(sorted(MULTILINGUAL_LANGUAGE_CODES))}"
            )
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS

        if "t3_model" in inspect.signature(ChatterboxMultilingualTTS.from_pretrained).parameters:
            return ChatterboxMultilingualTTS.from_pretrained(device=device, t3_model=t3_model)
        if t3_model:
            print("Installed chatterbox-tts does not support --t3-model; using its default multilingual model.", file=sys.stderr)
        return ChatterboxMultilingualTTS.from_pretrained(device=device)

    from chatterbox.tts import ChatterboxTTS

    return ChatterboxTTS.from_pretrained(device=device)


def run_server(args, *, runtime, model, initial_language: str, use_multilingual: bool) -> int:
    print(json.dumps({"ready": True, "sample_rate": model.sr}), flush=True)

    for line in sys.stdin:
        if not line.strip():
            continue
        request = {}
        try:
            request = json.loads(line)
            request_id = request.get("id")
            text = request["text"]
            output = Path(request["output"])
            language = normalize_language_code(request.get("language", initial_language))
            if language != "en" and not use_multilingual:
                raise ValueError("This worker was started with the English-only Chatterbox model.")
            if use_multilingual and language not in MULTILINGUAL_LANGUAGE_CODES:
                raise ValueError(
                    f"Chatterbox multilingual does not list language '{language}'. "
                    f"Supported: {', '.join(sorted(MULTILINGUAL_LANGUAGE_CODES))}"
                )
            output.parent.mkdir(parents=True, exist_ok=True)
            wav = generate_audio(
                model=model,
                text=text,
                language=language,
                voice_prompt=request.get("voice_prompt"),
                use_multilingual=use_multilingual,
            )
            runtime["torchaudio"].save(str(output), wav, model.sr)
            print(json.dumps({"id": request_id, "ok": True, "output": str(output)}), flush=True)
        except Exception as exc:  # noqa: BLE001 - worker must report failures without crashing.
            print(json.dumps({"id": request.get("id"), "ok": False, "error": str(exc)}), flush=True)

    return 0


def generate_audio(*, model, text: str, language: str, voice_prompt: str | None, use_multilingual: bool):
    if use_multilingual:
        return model.generate(text, language_id=language, audio_prompt_path=voice_prompt)
    return model.generate(text, audio_prompt_path=voice_prompt)


def normalize_language_code(language: str) -> str:
    code = language.strip().lower().replace("_", "-")
    if not code:
        return "en"
    return code.split("-", maxsplit=1)[0]


def choose_device(requested: str, torch_module) -> str:
    if requested != "auto":
        return requested
    if torch_module.cuda.is_available():
        return "cuda"
    if torch_module.backends.mps.is_available():
        return "mps"
    return "cpu"


def patch_missing_perth_watermarker(perth_module) -> None:
    if getattr(perth_module, "PerthImplicitWatermarker", None) is not None:
        return

    class NoOpWatermarker:
        def apply_watermark(self, wav, sample_rate):
            return wav

    perth_module.PerthImplicitWatermarker = NoOpWatermarker
    print(
        "Warning: resemble-perth does not provide PerthImplicitWatermarker on this platform; generated audio will not be watermarked.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    raise SystemExit(main())
