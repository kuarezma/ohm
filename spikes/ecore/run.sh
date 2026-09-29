#!/bin/bash
# T-012 gate: 4 x `yes`, 5 s per phase, BG policy on/off, prints before/after table.
# The binary spawns and kills its own `yes` children; policy touches only those pids.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin"
mkdir -p "$BIN"
clang -O2 -Wall -framework CoreFoundation -lIOReport -o "$BIN/ecore" "$HERE/ecore.c"
"$BIN/ecore" "${1:-4}" "${2:-5}"
