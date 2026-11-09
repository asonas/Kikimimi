#!/bin/bash
# Builds the probe and, for each container, kills the writer with SIGKILL at ~3 s, then reads the file back.
set -u
dir="$(cd "$(dirname "$0")" && pwd)"
out="$dir/out"
command rm -rf "$out"; mkdir -p "$out"
swiftc -O "$dir/probe.swift" -o "$dir/probe" 2>&1 | tail -5
for mode in m4a caf16 cafaac wav16; do
    ext=$mode
    case $mode in m4a) ext=m4a;; caf16|cafaac) ext=caf;; wav16) ext=wav;; esac
    file="$out/$mode.$ext"
    "$dir/probe" write "$mode" "$file" > "$out/$mode.log" 2>&1 &
    pid=$!
    sleep 3
    kill -9 $pid
    wait $pid 2>/dev/null
    echo "=== $mode: last write log: $(tail -1 "$out/$mode.log")"
    "$dir/probe" read "$file"
done
# Control: a clean exit (process ends normally, AVAudioFile released)
echo "=== control m4a (clean exit)"
"$dir/probe" write m4a "$out/control.m4a" > "$out/control.log" 2>&1
tail -1 "$out/control.log"
"$dir/probe" read "$out/control.m4a"
