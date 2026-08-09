#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import translategemma_mlx_translation  # noqa: E402


class FakeTokenizer:
    def __init__(self) -> None:
        self.messages = None
        self.options = None

    def apply_chat_template(self, messages, **options):
        self.messages = messages
        self.options = options
        return "rendered prompt"


class TranslateGemmaBridgeTests(unittest.TestCase):
    def test_uses_structured_translation_chat_template(self) -> None:
        tokenizer = FakeTokenizer()
        calls = []

        def generate(*args, **kwargs):
            calls.append((args, kwargs))
            return "  Dün önerdiğin kitap beklediğimden daha iyiydi.  "

        runtime = translategemma_mlx_translation.TranslationRuntime(
            model=object(),
            tokenizer=tokenizer,
            generate=generate,
            sampler=object(),
        )

        result = translategemma_mlx_translation.translate_text(
            runtime,
            "The book you recommended yesterday was better than I expected.",
            source_language="en_US",
            target_language="tr_tr",
            max_tokens=128,
        )

        self.assertEqual(result, "Dün önerdiğin kitap beklediğimden daha iyiydi.")
        self.assertEqual(
            tokenizer.messages,
            [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "source_lang_code": "en-US",
                            "target_lang_code": "tr-TR",
                            "text": "The book you recommended yesterday was better than I expected.",
                        }
                    ],
                }
            ],
        )
        self.assertEqual(
            tokenizer.options,
            {"add_generation_prompt": True, "tokenize": False},
        )
        self.assertEqual(calls[0][1]["prompt"], "rendered prompt")
        self.assertEqual(calls[0][1]["max_tokens"], 128)
        self.assertFalse(calls[0][1]["verbose"])

    def test_rejects_empty_source_text(self) -> None:
        runtime = translategemma_mlx_translation.TranslationRuntime(
            model=object(),
            tokenizer=FakeTokenizer(),
            generate=lambda *args, **kwargs: "unused",
            sampler=object(),
        )

        with self.assertRaisesRegex(ValueError, "source text is empty"):
            translategemma_mlx_translation.translate_text(
                runtime,
                "   ",
                source_language="en",
                target_language="tr",
                max_tokens=32,
            )

    def test_normalizes_regional_language_codes(self) -> None:
        self.assertEqual(
            translategemma_mlx_translation.normalize_language_code("TR_tr"),
            "tr-TR",
        )


if __name__ == "__main__":
    unittest.main()
