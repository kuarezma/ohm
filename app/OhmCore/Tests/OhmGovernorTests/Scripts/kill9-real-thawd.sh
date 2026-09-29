#!/bin/bash
# ADR 0004 § 10 test 1 with the shipping watcher binary (xcodebuild output) instead of the test host.
# Only touches processes this script starts: one `sleep`, the watcher, and the Ohm stand-in.
#   usage: kill9-real-thawd.sh <path to Ohm.app/Contents/MacOS/ohm-thawd>
set -uo pipefail
THAWD="${1:?path to ohm-thawd}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="$HERE/../../../.build/debug/OhmTestHost"
DIR="$(mktemp -d /tmp/ohm-t023-kill9.XXXXXX)"
stat_of() { ps -o stat= -p "$1" 2>/dev/null | tr -d ' '; }
ns() { python3 -c 'import time; print(time.time_ns())'; }

sleep 1000 & TARGET=$!
"$THAWD" --dir "$DIR" > "$DIR/thawd.log" 2>&1 & WATCHER=$!
OHM=""
cleanup() {
    kill -CONT "$TARGET" 2>/dev/null
    for p in $TARGET $WATCHER $OHM; do kill -9 "$p" 2>/dev/null; done
    wait 2>/dev/null
    rm -rf "$DIR"
}
trap cleanup EXIT

for _ in $(seq 1 100); do grep -q ready "$DIR/thawd.log" && break; sleep 0.02; done
"$HOST" ohm --dir "$DIR" --freeze-pid "$TARGET" > "$DIR/ohm.log" 2>&1 & OHM=$!
for _ in $(seq 1 250); do grep -q READY "$DIR/ohm.log" && break; sleep 0.02; done
echo "watcher=$WATCHER ($(basename "$THAWD")) ohm-standin=$OHM target=$TARGET"
grep -o "FREEZE .*" "$DIR/ohm.log" | cut -c1-40
echo "stat before kill -9: $(stat_of "$TARGET")"
T0=$(ns); kill -9 "$OHM"; wait "$OHM" 2>/dev/null
for _ in $(seq 1 500); do [[ "$(stat_of "$TARGET")" != *T* ]] && break; sleep 0.002; done
T1=$(ns)
echo "stat after kill -9: $(stat_of "$TARGET") after $(( (T1 - T0) / 1000000 )) ms"
sed 's/^\[[0-9]*\] //' "$DIR/thawd.log" | tail -2
