#!/usr/bin/env bash
# Headless gameplay assertions. Non-zero exit means a rule in GAME.md broke.
#   tools/run_tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT_BIN:-}"
if [ -z "${GODOT}" ]; then
	for cand in \
		"/c/Users/Asus/AppData/Local/Programs/Godot/Godot_v4.7.2-stable_win64_console.exe" \
		"/c/Users/Asus/AppData/Local/Programs/Godot/Godot_v4.7.2-stable_win64.exe" \
		"$(command -v godot 2>/dev/null || true)"; do
		if [ -n "$cand" ] && [ -x "$cand" ]; then GODOT="$cand"; break; fi
	done
fi
if [ -z "${GODOT}" ]; then echo "set GODOT_BIN to your Godot 4.7 binary" >&2; exit 2; fi

LOG="$(mktemp)"
timeout 240 "${GODOT}" --headless --path "${ROOT}" res://tests/SelfTest.tscn 2>&1 | tee "${LOG}" \
	| grep -E '^(PASS|FAIL|SELFTEST)' || true

# Engine runtime errors are a gate of their own: a passing assertion list with
# "Can't change this state while flushing queries" in the log means a collision
# callback silently skipped a frame, which no PASS line will ever reveal.
NOISE='RID allocations|PagedAllocator|string_name.cpp|thread.cpp|EditorNode|ResourceLoader'
NOISE_ERR=$(grep -E "SCRIPT ERROR|ERROR:" "${LOG}" | grep -Ev "${NOISE}" | sort -u)

echo
if [ -n "${NOISE_ERR}" ]; then
	echo "engine errors during the run:"
	echo "${NOISE_ERR}" | head -15
	fi
if grep -q "^SELFTEST OK" "${LOG}" && [ -z "${NOISE_ERR}" ]; then
	echo "tests passed, log clean"
	rm -f "${LOG}"
	exit 0
fi
echo "tests FAILED -- see the FAIL lines and engine errors above"
rm -f "${LOG}"
exit 1
