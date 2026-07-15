#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3.11}"
VENV_DIR="${HEPTAPOD_CHATTERBOX_MLX_VENV:-$ROOT_DIR/.venv-chatterbox-mlx}"
MLX_AUDIO_COMMIT="64e8416c303fb3b3463dab8eb4ebd78c55a87c1a"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Python 3.11 was not found at $PYTHON_BIN" >&2
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/pip" install \
  "mlx-audio[tts] @ git+https://github.com/Blaizzy/mlx-audio.git@$MLX_AUDIO_COMMIT"

"$VENV_DIR/bin/python" "$ROOT_DIR/Tools/chatterbox_mlx_tts.py" \
  --text "Yerel canli ceviri icin yuksek kaliteli ses hazir." \
  --language tr \
  --output /tmp/heptapod-chatterbox-mlx-setup.wav

echo "Chatterbox MLX is ready. Smoke output: /tmp/heptapod-chatterbox-mlx-setup.wav"
