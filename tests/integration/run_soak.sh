#!/bin/bash
# Usage: tests/integration/run_soak.sh <copy_dir> <mode> <seconds>
# Copies the project, imports, runs the soak test, prints errors and the summary.
set -u
P="$(cd "$(dirname "$0")/../.." && pwd)"
C="$1"; MODE="${2:-duel}"; SECS="${3:-60}"
G=/Applications/Godot_4_8.app/Contents/MacOS/Godot
rsync -a --delete --exclude .godot "$P/" "$C/"
"$G" --headless --path "$C" --import > /dev/null 2>&1
LOG="$C/soak_$MODE.log"
"$G" --headless --path "$C" ${FAST:+--fixed-fps 120} res://tests/integration/soak_test.tscn -- --mode="$MODE" --seconds="$SECS" > "$LOG" 2>&1 &
PID=$!
( sleep 900; kill -9 $PID ) > /dev/null 2>&1 &
WATCH=$!
wait $PID; CODE=$?
pkill -P $WATCH 2>/dev/null; kill $WATCH 2>/dev/null; wait $WATCH 2>/dev/null
echo "exit=$CODE"
echo "--- errors (unique, first 40)"
grep -E "SCRIPT ERROR|ERROR:|Parse Error|Invalid|Cannot" "$LOG" | sort | uniq -c | sort -rn | head -40
echo "--- error context (first 5 with stack)"
grep -A4 -E "SCRIPT ERROR" "$LOG" | head -40
echo "--- soak lines"
grep "\[soak\]" "$LOG" | tail -15
