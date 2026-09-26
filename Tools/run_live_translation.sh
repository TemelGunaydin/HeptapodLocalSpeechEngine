#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

export HF_DOWNLOAD_STALL_TIMEOUT="${HF_DOWNLOAD_STALL_TIMEOUT:-600}"

echo "Building with the active Xcode toolchain and matching macOS SDK..."
/usr/bin/xcrun swift build --product HeptapodLiveSpeechDemo

binary_dir="$(/usr/bin/xcrun swift build --show-bin-path)"
mlx_bundle="$binary_dir/mlx-swift_Cmlx.bundle"
metallib_script="$repo_root/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh"
# Swift Build already compiles Metal resources into the MLX bundle.
if [[ -s "$mlx_bundle/Contents/Resources/default.metallib" || -s "$mlx_bundle/default.metallib" ]]; then
    echo "Using the SwiftPM-built MLX Metal library."
elif [[ -x "$metallib_script" ]]; then
    BUILD_DIR="$repo_root/.build" "$metallib_script" debug
fi

binary_path="$binary_dir/HeptapodLiveSpeechDemo"
trace_path="${HEPTAPOD_TRACE_PATH:-/tmp/heptapod-live-tr.jsonl}"

exec "$binary_path" \
    --real \
    --system-audio \
    --play-output \
    --trace "$trace_path" \
    "$@"
