#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
test_dir="$(mktemp -d /private/tmp/heptapod-focused-tests.XXXXXX)"

swiftc -parse-as-library -swift-version 6 \
    Sources/HeptapodLocalSpeechEngine/Adapters/*.swift \
    Sources/HeptapodLocalSpeechEngine/Catalog/*.swift \
    Sources/HeptapodLocalSpeechEngine/Core/*.swift \
    Sources/HeptapodLocalSpeechEngine/Pipeline/*.swift \
    Tools/FocusedLivePipelineTests.swift \
    -o "$test_dir/focused-live-pipeline-tests"

"$test_dir/focused-live-pipeline-tests"
