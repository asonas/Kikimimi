#!/bin/bash
set -euo pipefail

# Local macOS voice only. This script neither downloads a model nor runs WhisperKit.
fixture_dir="$(dirname "$0")/Fixtures"
scratch="$(mktemp -d)"
trap 'command rm -rf "$scratch"' EXIT
mkdir -p "$fixture_dir"
/usr/bin/say -v Kyoko -r 155 -o "$scratch/sentence.aiff" 'これは面接の録音テストです。よろしくお願いします。'
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$scratch/sentence.aiff" \
    | awk '{ if ($1 <= 0) exit 1 }'
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$scratch/sentence.aiff" \
    -af 'adelay=8000:all=1,apad=whole_dur=20,atrim=duration=20' \
    -ar 16000 -ac 1 -c:a aac -b:a 32k "$fixture_dir/kyoko-20s.m4a"
ffmpeg -nostdin -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=r=16000:cl=mono:d=80' -i "$scratch/sentence.aiff" \
    -filter_complex '[1:a]asplit=2[a][b];[a]adelay=8000:all=1[first];[b]adelay=68000:all=1[last];[0:a][first][last]amix=inputs=3:duration=first:normalize=0[out]' \
    -map '[out]' -ar 16000 -ac 1 -c:a aac -b:a 32k "$fixture_dir/kyoko-80s.m4a"
