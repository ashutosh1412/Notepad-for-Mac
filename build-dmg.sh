#!/bin/bash
# Builds the release app and packages it into a compressed DMG with an Applications shortcut.
#
# Unsigned (default): ad-hoc signed, fine for your own Macs.
# Distribution: needs an Apple Developer ID and a notarytool keychain profile:
#   xcrun notarytool store-credentials notary --apple-id you@example.com --team-id TEAMID
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary bash build-dmg.sh
set -euo pipefail

PROTOTYPE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROTOTYPE_DIR/build"
APP_NAME="Notepad++"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PROTOTYPE_DIR/Info.plist")"
# Constant file name so the README link .../releases/latest/download/NotepadPlusPlus.dmg always works.
DMG_PATH="$BUILD_DIR/NotepadPlusPlus.dmg"
STAGING="$BUILD_DIR/dmg-staging"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

SIGN_IDENTITY="$SIGN_IDENTITY" DEBUG_HOOKS=0 bash "$PROTOTYPE_DIR/build.sh"

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
  fi
fi

hdiutil verify "$DMG_PATH" >/dev/null
echo "DMG: $DMG_PATH"
du -h "$DMG_PATH"
