#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
venv_path="${HEPTAPOD_QWEN_POSTEDIT_VENV:-$repo_root/.venv-qwen-postedit}"
python_bin="${PYTHON_BIN:-python3.11}"

if ! command -v "$python_bin" >/dev/null 2>&1; then
    echo "Python 3.11 is required. Install it or set PYTHON_BIN." >&2
    exit 1
fi

"$python_bin" -m venv "$venv_path"
"$venv_path/bin/python" -m pip install --upgrade pip
"$venv_path/bin/python" -m pip install "mlx-lm==0.31.3"

echo "Qwen post-edit environment is ready at $venv_path"
echo "The 4-bit model downloads on the first benchmark run."
