#!/bin/bash
# T-010 gate: 10 s idle + 10 s under one `yes` load, one line per second.
# Optional: `run.sh burst [secs]` averages the coarse CPU/DRAM counters per publish burst
# (runs one `yes` for the whole window).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin"
mkdir -p "$BIN"
clang -O2 -Wall -framework CoreFoundation -framework IOKit -lIOReport \
    -o "$BIN/ioreport" "$HERE/ioreport.c"
clang -O2 -Wall -framework CoreFoundation -lIOReport -o "$BIN/ioreport_scan" "$HERE/scan.c"

YES_PID=""
trap '[ -n "$YES_PID" ] && kill "$YES_PID" 2>/dev/null || true' EXIT

if [ "${1:-}" = "burst" ]; then
    yes > /dev/null & YES_PID=$!
    echo "# burst mode, yes pid=$YES_PID"
    "$BIN/ioreport" burst "${2:-300}"
    exit 0
fi

echo "# idle 10 s"
"$BIN/ioreport" 10
yes > /dev/null & YES_PID=$!
echo "# load: yes pid=$YES_PID, 10 s"
"$BIN/ioreport" 10
echo "# per-second energy channels across ALL IOReport groups (3 s, under load)"
"$BIN/ioreport_scan" 3
