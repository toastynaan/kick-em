#!/bin/bash
# Runs every module test scene headless on a private copy and reports PASS/FAIL.
# Usage: tests/run_all.sh <copy_dir> [module ...]   (modules: rig combat ai world game fx grab input)
# A test fails on a non-zero exit code or any SCRIPT ERROR / Parse Error line.
set -u
P="$(cd "$(dirname "$0")/.." && pwd)"
C="$1"; shift
MODULES="${*:-rig combat ai world game fx grab input}"
G=/Applications/Godot_4_8.app/Contents/MacOS/Godot
rsync -a --delete --exclude .godot "$P/" "$C/"
"$G" --headless --path "$C" --import > /dev/null 2>&1
mkdir -p "$C/_logs"
PASS=0; FAIL=0; FAILED=""
for m in $MODULES; do
	for t in "$C"/tests/$m/*.tscn; do
		[ -e "$t" ] || continue
		name="$m/$(basename "$t" .tscn)"
		log="$C/_logs/${name//\//_}.log"
		"$G" --headless --path "$C" --fixed-fps 120 "res://tests/$name.tscn" > "$log" 2>&1 &
		pid=$!
		( sleep 300; kill -9 $pid ) > /dev/null 2>&1 &
		watch=$!
		wait $pid; code=$?
		pkill -P $watch 2>/dev/null; kill $watch 2>/dev/null; wait $watch 2>/dev/null
		errs=$(grep -cE "SCRIPT ERROR|Parse Error" "$log")
		if [ "$code" = "0" ] && [ "$errs" = "0" ]; then
			PASS=$((PASS+1)); echo "PASS $name"
		else
			FAIL=$((FAIL+1)); FAILED="$FAILED $name"; echo "FAIL $name (exit=$code script_errors=$errs) log=$log"
		fi
	done
done
echo "TOTAL pass=$PASS fail=$FAIL${FAILED:+ failed:$FAILED}"
