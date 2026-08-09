#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
PYTHON_BIN="${PYTHON_BIN:-/opt/homebrew/bin/python3.11}"
VENV_DIR="${HEPTAPOD_TRANSLATEGEMMA_VENV:-$ROOT_DIR/.venv-translategemma}"
MLX_LM_VERSION="${MLX_LM_VERSION:-0.31.3}"

if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "Python 3.11 was not found at $PYTHON_BIN" >&2
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/pip" install "mlx-lm==$MLX_LM_VERSION"

"$VENV_DIR/bin/python" "$ROOT_DIR/Tools/translategemma_mlx_translation.py" \
  --text "The book you recommended yesterday was better than I expected." \
  --source-language en \
  --target-language tr \
  --warmup

echo "TranslateGemma MLX is ready."
