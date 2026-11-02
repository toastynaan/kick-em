#!/bin/bash
# F0 performance profile runner (tests/integration/perf_crowd.tscn).
# Usage: tests/integration/run_perf.sh <copy_dir> [runs] [-- perf options]
#   copy_dir  private copy (rsync'd from this project, never the project itself)
#   runs      how many measuring runs (default 1); each prints a PERF line
#   options   passed to perf_crowd.gd, e.g. -- --live=4 --corpses=awake
# Env: REALTIME=1 runs without --fixed-fps; NOSYNC=1 skips the rsync + import.
set -u
P="$(cd "$(dirname "$0")/../.." && pwd)"
C="$1"; shift
mkdir -p "$C"
if [ "$(cd "$C" && pwd)" = "$P" ]; then echo "refusing to run on the project itself; pass a private copy dir"; exit 2; fi
RUNS=1
if [ $# -gt 0 ] && [ "$1" != "--" ]; then RUNS="$1"; shift; fi
[ "${1:-}" = "--" ] && shift
G=/Applications/Godot_4_8.app/Contents/MacOS/Godot
if [ -z "${NOSYNC:-}" ]; then
	rsync -a --delete --exclude .godot --exclude '_perf' "$P/" "$C/"
	"$G" --headless --path "$C" --import > /dev/null 2>&1
fi
mkdir -p "$C/_perf"
FIX="--fixed-fps 120"; [ -n "${REALTIME:-}" ] && FIX=""
for i in $(seq 1 "$RUNS"); do
	LOG="$C/_perf/run_$(date +%s)_$i.log"
	"$G" --headless --path "$C" $FIX res://tests/integration/perf_crowd.tscn -- "$@" > "$LOG" 2>&1 &
	PID=$!
	( sleep 900; kill -9 $PID ) > /dev/null 2>&1 &
	WATCH=$!
	wait $PID; CODE=$?
	pkill -P $WATCH 2>/dev/null; kill $WATCH 2>/dev/null; wait $WATCH 2>/dev/null
	echo "--- run $i exit=$CODE log=$LOG"
	grep -E "SCRIPT ERROR|Parse Error" "$LOG" | sort | uniq -c | head -10
	grep -E "^\[perf\] (options|corpses|debris|warm|sampled|counts|events|band|  |TIME_|per-second)|^PERF " "$LOG"
done
