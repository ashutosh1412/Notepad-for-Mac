#!/bin/bash
# Builds Notepad++.app: a universal (Apple silicon + Intel) release build for macOS 11+.
#
# Environment:
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: Name (TEAMID)". Default: ad-hoc ("-").
#   DEBUG_HOOKS=1   include test hooks (snapshots, menu dump, self-test). Release builds leave them out.
#   OUTPUT_DIR      where the app is written. Default: native-prototype/build.
#   SCINTILLA_SOURCE / LEXILLA_SOURCE   use existing source trees (Lexilla needs a built bin/liblexilla.dylib).
set -euo pipefail

PROTOTYPE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROTOTYPE_DIR/build"
OUTPUT_DIR="${OUTPUT_DIR:-$BUILD_DIR}"
APP_NAME="Notepad++"
EXECUTABLE="NotepadPlusPlus"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DEBUG_HOOKS="${DEBUG_HOOKS:-0}"
SCINTILLA_VERSION="5.6.7"
LEXILLA_VERSION="5.5.4"
VENDOR_DIR="$BUILD_DIR/vendor/scintilla-$SCINTILLA_VERSION-lexilla-$LEXILLA_VERSION"
export MACOSX_DEPLOYMENT_TARGET="11.0"
ARCH_FLAGS=(-arch arm64 -arch x86_64)

if [[ -n "${SCINTILLA_SOURCE:-}" ]]; then
  SCINTILLA_DIR="$SCINTILLA_SOURCE"
  LEXILLA_DIR="${LEXILLA_SOURCE:?Set LEXILLA_SOURCE when building with SCINTILLA_SOURCE.}"
else
  # Pinned sources are cached so rebuilds don't download again.
  mkdir -p "$VENDOR_DIR"
  SCINTILLA_DIR="$VENDOR_DIR/scintilla"
  LEXILLA_DIR="$VENDOR_DIR/lexilla"
  for component in scintilla lexilla; do
    if [[ ! -d "$VENDOR_DIR/$component" ]]; then
      version="$SCINTILLA_VERSION"; [[ "$component" == lexilla ]] && version="$LEXILLA_VERSION"
      curl --fail --location --silent --show-error \
        "https://www.scintilla.org/${component}${version//./}.tgz" --output "$VENDOR_DIR/$component.tgz"
      tar -xzf "$VENDOR_DIR/$component.tgz" -C "$VENDOR_DIR"
      rm "$VENDOR_DIR/$component.tgz"
    fi
  done
  # Lexilla's makefile builds a universal dylib; rebuild it once for the deployment target.
  STAMP="$LEXILLA_DIR/bin/.built-for-macos-$MACOSX_DEPLOYMENT_TARGET"
  if [[ ! -f "$STAMP" ]]; then
    make --silent -C "$LEXILLA_DIR/src" clean >/dev/null 2>&1 || true
    make --silent -j8 -C "$LEXILLA_DIR/src"
    touch "$STAMP"
  fi
fi

# Compile Scintilla once per configuration and cache the objects; app sources always rebuild.
COMMON_FLAGS=(-std=c++17 -O2 -DNDEBUG -fobjc-arc -fmodules "${ARCH_FLAGS[@]}" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET"
              -I "$SCINTILLA_DIR/include" -I "$SCINTILLA_DIR/src" -I "$SCINTILLA_DIR/cocoa" -I "$LEXILLA_DIR/include" -I "$PROTOTYPE_DIR/src")
OBJECT_DIR="$BUILD_DIR/obj/macos-$MACOSX_DEPLOYMENT_TARGET-universal"
mkdir -p "$OBJECT_DIR/scintilla" "$OBJECT_DIR/app"
SCINTILLA_SOURCES=("$SCINTILLA_DIR"/src/*.cxx "$SCINTILLA_DIR/cocoa/PlatCocoa.mm" "$SCINTILLA_DIR/cocoa/ScintillaCocoa.mm"
                   "$SCINTILLA_DIR/cocoa/ScintillaView.mm" "$SCINTILLA_DIR/cocoa/InfoBar.mm")
APP_SOURCES=("$PROTOTYPE_DIR"/src/*.mm)

PIDS=()
for source in "${SCINTILLA_SOURCES[@]}"; do
  object="$OBJECT_DIR/scintilla/$(basename "$source").o"
  if [[ ! -f "$object" || "$source" -nt "$object" ]]; then
    clang++ "${COMMON_FLAGS[@]}" -w -c "$source" -o "$object" &
    PIDS+=($!)
  fi
done
for source in "${APP_SOURCES[@]}"; do
  clang++ "${COMMON_FLAGS[@]}" -DNATIVE_EDITOR_DEBUG_HOOKS="$DEBUG_HOOKS" -Wunguarded-availability-new \
    -c "$source" -o "$OBJECT_DIR/app/$(basename "$source").o" &
  PIDS+=($!)
done
FAILED=0
for pid in "${PIDS[@]}"; do wait "$pid" || FAILED=1; done
[[ "$FAILED" == 0 ]] || { echo "Compilation failed." >&2; exit 1; }

# Assemble the bundle.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"
cp "$PROTOTYPE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$LEXILLA_DIR/bin/liblexilla.dylib" "$APP_DIR/Contents/Frameworks/liblexilla.dylib"
cp "$SCINTILLA_DIR/License.txt" "$APP_DIR/Contents/Resources/Scintilla-License.txt"
cp "$LEXILLA_DIR/License.txt" "$APP_DIR/Contents/Resources/Lexilla-License.txt"
cp "$PROTOTYPE_DIR/Credits.rtf" "$APP_DIR/Contents/Resources/Credits.rtf"
# App icon from AppIcon.png (drawn by tools/make-icon.swift).
ICONSET="$OUTPUT_DIR/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$PROTOTYPE_DIR/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$PROTOTYPE_DIR/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
# Scintilla loads its busy and margin (reverse arrow) cursors as TIFFs from the bundle.
for image in mac_cursor_busy mac_cursor_flipped info_bar_bg; do
  tiffutil -cathidpicheck "$SCINTILLA_DIR/cocoa/res/$image.png" "$SCINTILLA_DIR/cocoa/res/$image@2x.png" \
    -out "$APP_DIR/Contents/Resources/$image.tiff" >/dev/null 2>&1
done

clang++ "${ARCH_FLAGS[@]}" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -fobjc-arc -Wl,-dead_strip \
  "$OBJECT_DIR"/scintilla/*.o "$OBJECT_DIR"/app/*.o \
  -framework Cocoa -framework UniformTypeIdentifiers -framework QuartzCore \
  -Wl,-rpath,@executable_path/../Frameworks \
  -o "$APP_DIR/Contents/MacOS/$EXECUTABLE"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

# Sign inside-out. A real identity gets the hardened runtime and a secure timestamp,
# which notarization requires.
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
codesign "${SIGN_FLAGS[@]}" "$APP_DIR/Contents/Frameworks/liblexilla.dylib"
codesign "${SIGN_FLAGS[@]}" "$APP_DIR"
codesign --verify --strict "$APP_DIR"

echo "Built: $APP_DIR ($(lipo -archs "$APP_DIR/Contents/MacOS/$EXECUTABLE"), macOS $MACOSX_DEPLOYMENT_TARGET+, signed: $SIGN_IDENTITY)"
du -sh "$APP_DIR"
