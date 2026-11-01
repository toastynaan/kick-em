#!/bin/bash
# Usage: tests/fx/run_fx_tests.sh <copy_dir>
# Copies the project to <copy_dir>, imports, runs every tests/fx test headless,
# and fails on a non-zero exit or any SCRIPT ERROR / ERROR: / Parse Error line.
set -u
P="$(cd "$(dirname "$0")/../.." && pwd)"
C="$1"
G=/Applications/Godot_4_8.app/Contents/MacOS/Godot
rsync -a --delete --exclude .godot "$P/" "$C/"
"$G" --headless --path "$C" --import > /dev/null 2>&1
FAILED=0
for T in "$P"/tests/fx/test_*.tscn; do
	N="$(basename "$T" .tscn)"
	LOG="$C/fx_$N.log"
	"$G" --headless --path "$C" --fixed-fps 120 "res://tests/fx/$N.tscn" > "$LOG" 2>&1
	CODE=$?
	ERRS=$(grep -cE "SCRIPT ERROR|^ERROR:|Parse Error" "$LOG")
	if [ "$CODE" -ne 0 ] || [ "$ERRS" -ne 0 ]; then
		FAILED=1
		echo "FAIL $N (exit $CODE, $ERRS error lines)"
		grep -E "FAIL|SCRIPT ERROR|^ERROR:|Parse Error" "$LOG" | head -10
	else
		echo "PASS $N"
	fi
done
exit $FAILED
