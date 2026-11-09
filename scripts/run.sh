#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/logs
log="$PWD/build/logs/$(date +%Y%m%d-%H%M%S)-$$"
echo "stdout: $log.stdout.log"
echo "stderr: $log.stderr.log"
echo 'Ctrl-C/SIGTERM の検証はアプリの PID に kill -INT / kill -TERM を送ってください。'
open -n -W --stdout "$log.stdout.log" --stderr "$log.stderr.log" "$PWD/build/InterviewRecorderSpike.app" --args "$@"
