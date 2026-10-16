#!/bin/bash
# Builds a test variant (with debug hooks) into build/debug and runs the in-app
# command self-test (menu commands against a real editor).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEBUG_HOOKS=1 OUTPUT_DIR="$ROOT/build/debug" bash "$ROOT/build.sh" >/dev/null || exit 1
APP="$ROOT/build/debug/Notepad++.app/Contents/MacOS/NotepadPlusPlus"
REPORT="$(mktemp -t notepad-selftest)"
NATIVE_EDITOR_SELFTEST="$REPORT" "$APP" -NativeEditorNoSession YES >/dev/null 2>&1
STATUS=$?
cat "$REPORT"
rm -f "$REPORT"
exit $STATUS
