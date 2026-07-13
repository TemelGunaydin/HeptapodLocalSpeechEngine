#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

export HF_DOWNLOAD_STALL_TIMEOUT="${HF_DOWNLOAD_STALL_TIMEOUT:-600}"

echo "Building with the active Xcode toolchain and matching macOS SDK..."
/usr/bin/xcrun swift build --product HeptapodLiveSpeechDemo

metallib_script="$repo_root/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh"
if [[ -x "$metallib_script" ]]; then
    BUILD_DIR="$repo_root/.build" "$metallib_script" debug
fi

binary_path="$(/usr/bin/xcrun swift build --show-bin-path)/HeptapodLiveSpeechDemo"
trace_path="${HEPTAPOD_TRACE_PATH:-/tmp/heptapod-live-tr.jsonl}"

exec "$binary_path" \
    --real \
    --system-audio \
    --play-output \
    --trace "$trace_path" \
    "$@"
