#!/usr/bin/env python3
"""Local streaming MOSS-TTS-Nano bridge for Heptapod.

The worker uses the official ONNX Runtime export, keeps every inference session
resident, and exposes decoded mono PCM16 chunks over a JSON-lines protocol.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
import time
import wave
from pathlib import Path
from typing import Callable

import numpy as np


DEFAULT_CACHE_DIRECTORY = (
    Path.home()
    / "Library"
    / "Caches"
    / "HeptapodLocalSpeechEngine"
    / "MOSS-TTS-Nano-ONNX"
)
DEFAULT_VOICE = "Ava"
MINIMUM_EMIT_SECONDS = 0.16
SUPPORTED_LANGUAGE_CODES = {
    "ar",
    "cs",
    "da",
    "de",
    "el",
    "en",
    "es",
    "fa",
    "fr",
    "hu",
    "it",
    "ja",
    "ko",
    "pl",
    "pt",
    "ru",
    "sv",
    "tr",
    "zh",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate streaming speech with MOSS-TTS-Nano ONNX.")
    parser.add_argument("--server", action="store_true", help="Run a persistent JSON-lines worker.")
    parser.add_argument("--text", help="Text for one-shot synthesis.")
    parser.add_argument("--output", help="Mono PCM16 WAV output for one-shot synthesis.")
    parser.add_argument("--language", default="tr", help="BCP-47-ish output language code.")
    parser.add_argument("--voice", default=DEFAULT_VOICE, help="Built-in voice preset.")
    parser.add_argument("--voice-prompt", help="Optional reference audio for voice cloning.")
    parser.add_argument("--model-dir", default=str(DEFAULT_CACHE_DIRECTORY), help="ONNX model cache directory.")
    parser.add_argument("--cpu-threads", type=int, default=8, help="ONNX Runtime intra-op threads.")
    parser.add_argument("--sample-mode", choices=["greedy", "fixed", "full"], default="fixed")
    parser.add_argument("--seed", type=int, default=1234)
    parser.add_argument("--no-warmup", action="store_true", help="Skip startup warmup.")
    args = parser.parse_args()

    if not args.server and (not args.text or not args.output):
        parser.error("--text and --output are required unless --server is used")

    runtime_module, runtime = load_runtime(
        model_directory=Path(args.model_dir),
        cpu_threads=args.cpu_threads,
        sample_mode=args.sample_mode,
    )
    voices = [str(item["voice"]) for item in runtime.list_builtin_voices()]
    if args.voice not in voices:
        parser.error(f"unknown built-in voice '{args.voice}'; available: {', '.join(voices)}")

    if not args.no_warmup:
        runtime.warmup()

    if args.server:
        return run_server(args, runtime_module=runtime_module, runtime=runtime, voices=voices)

    language = normalize_language_code(args.language)
    validate_language(language)
    chunks: list[bytes] = []
    metrics = stream_synthesis(
        runtime_module=runtime_module,
        runtime=runtime,
        text=args.text,
        language=language,
        voice=args.voice,
        voice_prompt=args.voice_prompt,
        seed=args.seed,
        emit_chunk=chunks.append,
    )
    write_wav(Path(args.output), chunks, metrics["sample_rate"])
    print(json.dumps(metrics, ensure_ascii=False))
    return 0


def load_runtime(*, model_directory: Path, cpu_threads: int, sample_mode: str):
    try:
        import onnx_tts_runtime as runtime_module
    except ImportError as exc:
        print(
            "Missing MOSS-TTS-Nano dependencies. Run Tools/setup_moss_tts_nano.sh.",
            file=sys.stderr,
        )
        raise exc

    # The official downloader only auto-populates its configured default path.
    # Redirect that path to the application's cache instead of site-packages.
    runtime_module.DEFAULT_BROWSER_ONNX_MODEL_DIR = model_directory.expanduser().resolve()
    runtime = runtime_module.OnnxTtsRuntime(
        model_dir=None,
        thread_count=max(1, int(cpu_threads)),
        sample_mode=sample_mode,
    )
    return runtime_module, runtime


def run_server(args, *, runtime_module, runtime, voices: list[str]) -> int:
    sample_rate = int(runtime.codec_meta["codec_config"]["sample_rate"])
    ready = {
        "ready": True,
        "backend": "moss-tts-nano-onnx",
        "sample_rate": sample_rate,
        "voices": voices,
    }
    print(json.dumps(ready, ensure_ascii=False), flush=True)

    for line in sys.stdin:
        if not line.strip():
            continue
        request: dict[str, object] = {}
        try:
            request = json.loads(line)
            request_id = str(request.get("id") or "")
            language = normalize_language_code(str(request.get("language") or "tr"))
            validate_language(language)
            requested_voice = str(request.get("voice_id") or args.voice)
            voice = requested_voice if requested_voice in voices else args.voice
            voice_prompt = request.get("voice_prompt") or args.voice_prompt
            seed = int(request.get("seed") or args.seed)

            def emit_audio(pcm16: bytes) -> None:
                event = {
                    "id": request_id,
                    "event": "audio",
                    "sample_rate": sample_rate,
                    "pcm16": base64.b64encode(pcm16).decode("ascii"),
                }
                print(json.dumps(event, separators=(",", ":")), flush=True)

            metrics = stream_synthesis(
                runtime_module=runtime_module,
                runtime=runtime,
                text=str(request["text"]),
                language=language,
                voice=voice,
                voice_prompt=str(voice_prompt) if voice_prompt else None,
                seed=seed,
                emit_chunk=emit_audio,
            )
            print(
                json.dumps(
                    {"id": request_id, "event": "done", **metrics},
                    separators=(",", ":"),
                ),
                flush=True,
            )
        except Exception as exc:  # noqa: BLE001 - worker must survive request errors.
            print(
                json.dumps(
                    {
                        "id": request.get("id"),
                        "event": "error",
                        "error": str(exc),
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
                flush=True,
            )
    return 0


def stream_synthesis(
    *,
    runtime_module,
    runtime,
    text: str,
    language: str,
    voice: str,
    voice_prompt: str | None,
    seed: int,
    emit_chunk: Callable[[bytes], None],
) -> dict[str, object]:
    normalized_text = str(text or "").strip()
    if not normalized_text:
        raise ValueError("text is required")
    validate_language(language)
    if voice_prompt and not Path(voice_prompt).expanduser().is_file():
        raise FileNotFoundError(f"voice prompt not found: {voice_prompt}")

    runtime.rng = np.random.default_rng(seed)
    prepared = runtime.prepare_synthesis_text(
        text=normalized_text,
        voice=voice,
        enable_wetext=False,
        enable_normalize_tts_text=True,
    )
    prepared_text = str(prepared["text"])
    prompt_audio_codes = runtime.resolve_prompt_audio_codes(
        voice=voice,
        prompt_audio_path=voice_prompt,
    )
    text_chunks = runtime.split_voice_clone_text(prepared_text, max_tokens=75)
    if not text_chunks:
        text_chunks = [prepared_text]

    sample_rate = int(runtime.codec_meta["codec_config"]["sample_rate"])
    minimum_emit_samples = max(1, int(round(sample_rate * MINIMUM_EMIT_SECONDS)))
    started_at = time.perf_counter()
    first_audio_latency: float | None = None
    emitted_samples = 0
    emitted_chunks = 0

    def emit_waveform(waveform: np.ndarray, *, force: bool = False) -> None:
        nonlocal first_audio_latency, emitted_samples, emitted_chunks
        mono = downmix_mono(waveform)
        if mono.size == 0:
            return
        pcm16 = float_to_pcm16(mono)
        if not pcm16 and not force:
            return
        if first_audio_latency is None:
            first_audio_latency = time.perf_counter() - started_at
        emitted_samples += len(pcm16) // 2
        emitted_chunks += 1
        emit_chunk(pcm16)

    for text_index, text_chunk in enumerate(text_chunks):
        request_rows = runtime.build_voice_clone_request_rows(
            prompt_audio_codes,
            runtime.encode_text(text_chunk),
        )
        pending_frames: list[list[int]] = []
        pending_waveforms: list[np.ndarray] = []
        pending_sample_count = 0
        decoder_emitted_samples = 0
        decoder_first_audio_at: float | None = None
        runtime.codec_streaming_session.reset()

        def flush_waveforms(force: bool) -> None:
            nonlocal pending_sample_count
            if not pending_waveforms:
                return
            if not force and pending_sample_count < minimum_emit_samples:
                return
            waveform = np.concatenate(pending_waveforms, axis=0)
            pending_waveforms.clear()
            pending_sample_count = 0
            emit_waveform(waveform, force=force)

        def decode_pending_frames(force: bool) -> None:
            nonlocal decoder_emitted_samples, decoder_first_audio_at, pending_sample_count
            if not pending_frames:
                return
            budget = runtime_module._resolve_stream_decode_frame_budget(
                decoder_emitted_samples,
                sample_rate,
                decoder_first_audio_at,
            )
            if not force and len(pending_frames) < max(1, budget):
                return
            frame_count = len(pending_frames) if force else min(len(pending_frames), max(1, budget))
            frame_chunk = pending_frames[:frame_count]
            del pending_frames[:frame_count]
            decoded = runtime.codec_streaming_session.run_frames(frame_chunk)
            if decoded is None:
                return
            audio, audio_length = decoded
            if audio_length <= 0:
                return
            if decoder_first_audio_at is None:
                decoder_first_audio_at = time.perf_counter()
            decoder_emitted_samples += audio_length
            waveform = runtime_module._merge_audio_channels(
                [audio[0, channel_index, :audio_length] for channel_index in range(audio.shape[1])]
            )
            pending_waveforms.append(waveform)
            pending_sample_count += audio_length
            flush_waveforms(force=False)

        def on_frame(_generated_frames, _step_index: int, frame: list[int]) -> None:
            pending_frames.append(list(frame))
            decode_pending_frames(force=False)

        try:
            runtime.generate_audio_frames(request_rows, on_frame=on_frame)
            decode_pending_frames(force=True)
            flush_waveforms(force=True)
        finally:
            runtime.codec_streaming_session.reset()

        if text_index < len(text_chunks) - 1:
            pause_seconds = runtime.estimate_voice_clone_inter_chunk_pause_seconds(text_chunk)
            emit_waveform(np.zeros((int(round(sample_rate * pause_seconds)), 1), dtype=np.float32))

    elapsed_seconds = time.perf_counter() - started_at
    audio_seconds = emitted_samples / float(sample_rate)
    return {
        "sample_rate": sample_rate,
        "elapsed_seconds": elapsed_seconds,
        "first_audio_latency_seconds": first_audio_latency,
        "audio_seconds": audio_seconds,
        "real_time_factor": elapsed_seconds / audio_seconds if audio_seconds > 0 else None,
        "chunk_count": emitted_chunks,
        "voice": voice,
        "language": language,
    }


def downmix_mono(waveform: np.ndarray) -> np.ndarray:
    audio = np.asarray(waveform, dtype=np.float32)
    if audio.ndim == 1:
        return audio
    if audio.ndim != 2:
        raise ValueError(f"unsupported waveform shape: {audio.shape}")
    return audio.mean(axis=1, dtype=np.float32)


def float_to_pcm16(samples: np.ndarray) -> bytes:
    clipped = np.clip(np.asarray(samples, dtype=np.float32), -1.0, 1.0)
    return np.round(clipped * 32767.0).astype("<i2", copy=False).tobytes()


def write_wav(path: Path, chunks: list[bytes], sample_rate: int) -> None:
    output = path.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        for chunk in chunks:
            wav_file.writeframes(chunk)


def normalize_language_code(language: str) -> str:
    normalized = language.strip().lower().replace("_", "-")
    return normalized.split("-", maxsplit=1)[0] if normalized else "tr"


def validate_language(language: str) -> None:
    if language not in SUPPORTED_LANGUAGE_CODES:
        raise ValueError(
            f"MOSS-TTS-Nano does not list language '{language}'. "
            f"Supported: {', '.join(sorted(SUPPORTED_LANGUAGE_CODES))}"
        )


if __name__ == "__main__":
    raise SystemExit(main())
