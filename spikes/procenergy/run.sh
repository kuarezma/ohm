#!/bin/bash
# T-011 gate: build, start one `yes` load, list top-10 energy consumers over 5 s, kill the load.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin"
mkdir -p "$BIN"
clang -O2 -Wall -o "$BIN/procenergy" "$HERE/procenergy.c"

yes > /dev/null &
YES_PID=$!
trap 'kill "$YES_PID" 2>/dev/null || true' EXIT
echo "started yes pid=$YES_PID"
sleep 1
"$BIN/procenergy" "${1:-5}" 10
