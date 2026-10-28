#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
python_bin="${PYTHON_BIN:-/opt/homebrew/bin/python3.11}"
venv_dir="${HEPTAPOD_POCKET_VENV:-$repo_root/.venv-pocket-tts}"

if [[ ! -x "$venv_dir/bin/python" ]]; then
    "$python_bin" -m venv "$venv_dir"
fi
requirements=(
    'pocket-tts-turkish @ git+https://github.com/witetech/pocket-tts-turkish.git@88df358df6b57fb6bddaa82ac7d2d856521b7a20'
    'pocket-tts==3.3.0'
    'torch==2.15.0'
)
if command -v uv >/dev/null 2>&1; then
    uv pip install --system-certs --python "$venv_dir/bin/python" "${requirements[@]}"
else
    "$venv_dir/bin/python" -m pip install "${requirements[@]}"
fi
"$venv_dir/bin/python" "$repo_root/Tools/pocket_turkish_tts.py" \
    --text 'Merhaba. Türkçe canlı çeviri için ses modeli hazır.' \
    --output /tmp/heptapod-pocket-setup.wav
echo 'Pocket Turkish TTS is ready. Output: /tmp/heptapod-pocket-setup.wav'
