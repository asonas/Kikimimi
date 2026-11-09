#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

latest=""
for candidate in build/logs/*.stderr.log; do
    [[ -f "$candidate" ]] || continue
    if [[ -z "$latest" || "$candidate" -nt "$latest" ]]; then
        latest="$candidate"
    fi
done
if [[ -z "$latest" ]]; then
    echo "No stderr log found in build/logs" >&2
    exit 1
fi
echo "stderr: $latest"
pid=$(sed -nE 's/^InterviewRecorderSpike PID: ([0-9]+)$/\1/p' "$latest" | head -n 1)
if [[ -z "$pid" ]]; then
    echo "No InterviewRecorderSpike PID found in latest log" >&2
    exit 1
fi
if grep -q '^Finished:' "$latest"; then
    tail -n 20 "$latest"
    exit 0
fi
# A stale log must never signal an unrelated process that reused this PID.
process=$(ps -p "$pid" -o comm= || true)
if [[ "${process##*/}" != InterviewRecorderSpike ]]; then
    echo "PID $pid is not a running InterviewRecorderSpike" >&2
    tail -n 20 "$latest"
    exit 1
fi
echo "Sending SIGINT to InterviewRecorderSpike PID: $pid"
kill -INT "$pid"
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    if grep -q '^Finished:' "$latest"; then
        tail -n 20 "$latest"
        exit 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        # Recheck after process exit in case the last write raced the previous read.
        if grep -q '^Finished:' "$latest"; then
            tail -n 20 "$latest"
            exit 0
        fi
        echo "Recorder exited without Finished:" >&2
        tail -n 20 "$latest"
        exit 1
    fi
    sleep 1
done
echo "Timed out after 30 seconds waiting for Finished:" >&2
tail -n 20 "$latest"
exit 1
