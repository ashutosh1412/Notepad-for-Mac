#!/bin/bash
# Builds and runs the headless NativeDocument checks. Run build.sh once first
# so the pinned Scintilla and Lexilla sources are in build/vendor.
set -euo pipefail

PROTOTYPE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROTOTYPE_DIR/src"
VENDOR_DIR="$PROTOTYPE_DIR/build/vendor/scintilla-5.6.7-lexilla-5.5.4"
SCINTILLA_DIR="$VENDOR_DIR/scintilla"
LEXILLA_DIR="$VENDOR_DIR/lexilla"
OUTPUT="$PROTOTYPE_DIR/build/native-document-tests"

if [[ ! -f "$LEXILLA_DIR/bin/liblexilla.dylib" ]]; then
  echo "Run native-prototype/build.sh first." >&2
  exit 1
fi

clang++ -std=c++17 -O1 -fobjc-arc -fmodules -w \
  -I "$SCINTILLA_DIR/include" -I "$SCINTILLA_DIR/src" -I "$SCINTILLA_DIR/cocoa" \
  -I "$LEXILLA_DIR/include" -I "$SRC" \
  "$SCINTILLA_DIR"/src/*.cxx \
  "$SCINTILLA_DIR/cocoa/PlatCocoa.mm" "$SCINTILLA_DIR/cocoa/ScintillaCocoa.mm" \
  "$SCINTILLA_DIR/cocoa/ScintillaView.mm" "$SCINTILLA_DIR/cocoa/InfoBar.mm" \
  "$SRC/NativeLanguages.mm" "$SRC/NativeDocument.mm" \
  "$PROTOTYPE_DIR/tests/NativeDocumentTests.mm" \
  -framework Cocoa -framework QuartzCore \
  -o "$OUTPUT"

"$OUTPUT" "$LEXILLA_DIR/bin/liblexilla.dylib"
