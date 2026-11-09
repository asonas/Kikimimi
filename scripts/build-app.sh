#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
identity=${CODE_SIGN_IDENTITY:-Apple Development: Yuya Fujiwara (55CYFEJC5B)}
signing_options=(--timestamp)
if [[ "${CODE_SIGN_RUNTIME:-1}" != 0 ]]; then
    signing_options+=(--options runtime)
fi
command -v swift
swift --version
swift build -c release
app="$PWD/build/InterviewRecorderSpike.app"
mkdir -p "$app/Contents/MacOS"
command cp .build/release/InterviewRecorderSpike "$app/Contents/MacOS/InterviewRecorderSpike"
command cp scripts/Info.plist "$app/Contents/Info.plist"
codesign --force "${signing_options[@]}" --entitlements scripts/InterviewRecorderSpike.entitlements --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"
codesign -dv --verbose=2 "$app"
