#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3.11}"
VENV_DIR="${HEPTAPOD_MOSS_VENV:-$ROOT_DIR/.venv-moss-tts-nano}"
MOSS_COMMIT="11619374849c649486584e3b10ed55b176a924ee"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Python 3.11 was not found at $PYTHON_BIN" >&2
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/pip" install \
  "git+https://github.com/OpenMOSS/MOSS-TTS-Nano.git@$MOSS_COMMIT" \
  huggingface_hub

"$VENV_DIR/bin/python" "$ROOT_DIR/Tools/moss_tts_nano_bridge.py" \
  --text "Yerel canli ceviri sesi hazir." \
  --language tr \
  --voice Ava \
  --output /tmp/heptapod-moss-tts-nano-setup.wav

echo "MOSS-TTS-Nano is ready. Smoke output: /tmp/heptapod-moss-tts-nano-setup.wav"
