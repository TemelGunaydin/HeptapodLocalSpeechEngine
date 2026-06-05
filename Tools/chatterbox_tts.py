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
    parser.add_argument("--text", required=True, help="Text to synthesize.")
    parser.add_argument("--language", default="en", help="BCP-47-ish target language code, such as en, tr, es, fr.")
    parser.add_argument("--output", required=True, help="Output WAV path.")
    parser.add_argument("--voice-prompt", help="Optional 5-10 second reference WAV for voice cloning.")
    parser.add_argument("--voice-id", help="Reserved for future named-voice selection; currently ignored.")
    parser.add_argument("--device", choices=["auto", "cpu", "mps", "cuda"], default="auto", help="Torch device.")
    parser.add_argument("--multilingual", action="store_true", help="Force ChatterboxMultilingualTTS.")
    parser.add_argument("--t3-model", help="Optional multilingual T3 model, for example v2 or v3.")
    args = parser.parse_args()

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)

    try:
        import torch
        import torchaudio as ta
        import perth
    except ImportError as exc:
        print(
            "Missing Python dependency. Install with: pip install chatterbox-tts torchaudio",
            file=sys.stderr,
        )
        raise exc

    language = normalize_language_code(args.language)
    device = choose_device(args.device, torch)
    use_multilingual = args.multilingual or language != "en"
    patch_missing_perth_watermarker(perth)

    if use_multilingual:
        if language not in MULTILINGUAL_LANGUAGE_CODES:
            raise ValueError(
                f"Chatterbox multilingual does not list language '{language}'. "
                f"Supported: {', '.join(sorted(MULTILINGUAL_LANGUAGE_CODES))}"
            )
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS

        if "t3_model" in inspect.signature(ChatterboxMultilingualTTS.from_pretrained).parameters:
            model = ChatterboxMultilingualTTS.from_pretrained(device=device, t3_model=args.t3_model)
        else:
            if args.t3_model:
                print("Installed chatterbox-tts does not support --t3-model; using its default multilingual model.", file=sys.stderr)
            model = ChatterboxMultilingualTTS.from_pretrained(device=device)
        wav = model.generate(args.text, language_id=language, audio_prompt_path=args.voice_prompt)
    else:
        from chatterbox.tts import ChatterboxTTS

        model = ChatterboxTTS.from_pretrained(device=device)
        wav = model.generate(args.text, audio_prompt_path=args.voice_prompt)

    ta.save(str(output), wav, model.sr)
    print(f"Wrote {output} at {model.sr} Hz")
    return 0


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
