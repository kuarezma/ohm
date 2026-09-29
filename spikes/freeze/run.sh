#!/bin/bash
# T-013 gate. Only touches the TextEdit instance this script launches itself.
#  (1) freeze -> ps stat must contain T
#  (2) `open -a TextEdit` -> SIGCONT latency (3 trials), target < 300 ms
#  (3) agent killed with -9 while target frozen -> watchdog thaws it
#  (3b) agent AND watchdog killed with -9 -> next-launch `recover` thaws it
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin"
mkdir -p "$BIN"
swiftc -O -o "$BIN/freeze-agent" "$HERE/FreezeAgent.swift" || exit 1
AGENT="$BIN/freeze-agent"
JOURNAL="$BIN/freeze.journal"
LOG="$BIN/freeze.log"
: > "$LOG"; rm -f "$JOURNAL"
ns() { python3 -c 'import time; print(time.time_ns())'; }
stat_of() { ps -o stat= -p "$1" 2>/dev/null | tr -d ' '; }

if pgrep -x TextEdit >/dev/null; then
    echo "ABORT: a TextEdit instance is already running (user's); refusing to test"; exit 1
fi
open -na TextEdit
TE=""
for _ in $(seq 1 100); do TE=$(pgrep -x TextEdit | head -1); [ -n "$TE" ] && break; sleep 0.1; done
[ -z "$TE" ] && { echo "TextEdit did not start"; exit 1; }
echo "our TextEdit pid=$TE"
sleep 2

AG=""; WD=""
cleanup() {
    for p in $AG $WD; do kill -9 "$p" 2>/dev/null; done
    kill -CONT "$TE" 2>/dev/null; kill -TERM "$TE" 2>/dev/null; sleep 1
    kill -9 "$TE" 2>/dev/null
    rm -f "$JOURNAL"
    echo "cleanup: TextEdit $TE alive? $(ps -p "$TE" >/dev/null && echo yes || echo no)"
}
trap cleanup EXIT

start_agent() {
    "$AGENT" agent "$TE" "$JOURNAL" >> "$LOG" 2>&1 &
    AG=$!
    for _ in $(seq 1 50); do
        WD=$(grep -o "agent: pid=$AG watchdog pid=[0-9]*" "$LOG" | sed 's/.*=//')
        [ -n "$WD" ] && grep -q "FROZE pid=$TE" <(sed -n "/agent: pid=$AG /,\$p" "$LOG") && break
        sleep 0.1
    done
    echo "agent pid=$AG watchdog pid=$WD"
}
wait_stat() { # wait_stat <want T|notT> <timeout_s>
    local end=$(( $(date +%s) + $2 ))
    while [ "$(date +%s)" -le "$end" ]; do
        s=$(stat_of "$TE")
        if [ "$1" = T ] && [[ "$s" == *T* ]]; then return 0; fi
        if [ "$1" = notT ] && [[ "$s" != *T* ]]; then return 0; fi
        sleep 0.02
    done
    return 1
}

echo "== (1) freeze"
start_agent
echo "ps stat after freeze: $(stat_of "$TE")"

echo "== (2) activation -> SIGCONT latency"
for trial in 1 2 3; do
    n_before=$(grep -c "THAWED pid=$TE" "$LOG")
    t0=$(ns)
    open -a TextEdit
    for _ in $(seq 1 250); do
        [ "$(grep -c "THAWED pid=$TE" "$LOG")" -gt "$n_before" ] && break; sleep 0.02
    done
    line=$(grep "THAWED pid=$TE" "$LOG" | tail -1)
    if [ "$(grep -c "THAWED pid=$TE" "$LOG")" -gt "$n_before" ]; then
        t1=$(echo "$line" | sed 's/^\[\([0-9]*\)\].*/\1/')
        echo "trial $trial: SIGCONT latency from 'open -a' = $(( (t1 - t0) / 1000000 )) ms; stat=$(stat_of "$TE")"
    else
        echo "trial $trial: NO THAW within 5 s; stat=$(stat_of "$TE")"
    fi
    [ $trial -lt 3 ] && { kill -USR1 "$AG"; wait_stat T 3; echo "  re-frozen: stat=$(stat_of "$TE")"; }
done

echo "== (3) kill -9 agent while frozen -> watchdog"
kill -USR1 "$AG"; wait_stat T 3
echo "stat before kill -9: $(stat_of "$TE")  journal: $(cat "$JOURNAL" 2>/dev/null)"
tk=$(ns); kill -9 "$AG"; wait "$AG" 2>/dev/null
if wait_stat notT 3; then
    echo "watchdog thawed after $(( ($(ns) - tk) / 1000000 )) ms; stat=$(stat_of "$TE")"
else
    echo "FAIL: still frozen 3 s after agent kill; stat=$(stat_of "$TE")"
fi
grep "watchdog:" "$LOG" | tail -3 | sed 's/^\[[0-9]*\] //'

echo "== (3b) kill -9 agent AND watchdog -> next-launch recovery"
start_agent
echo "stat: $(stat_of "$TE")"
kill -9 "$WD"; kill -9 "$AG"; wait "$AG" 2>/dev/null; sleep 0.5
echo "after both killed: stat=$(stat_of "$TE") journal: $(cat "$JOURNAL" 2>/dev/null)"
"$AGENT" recover "$JOURNAL" | sed 's/^\[[0-9]*\] //'
echo "after recover: stat=$(stat_of "$TE")"
AG=""; WD=""
