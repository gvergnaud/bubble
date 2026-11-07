#!/bin/bash
# Builds the downloadable Bubble: build/release/Bubble-<version>.zip (+ .sha256).
#   scripts/release.sh
# Release build (scripts/build-app.sh release), then signed again with the hardened runtime, a secure
# timestamp and Resources/Bubble.entitlements, which notarization needs. Needs a "Developer ID
# Application" identity ($BUBBLE_SIGN_IDENTITY, else the first one in the keychain).
# Notarization: set NOTARY_PROFILE to a notarytool keychain profile, made once with
#   xcrun notarytool store-credentials bubble-notary --apple-id <you@example.com> --team-id <TEAMID>
# (it asks for an app-specific password from account.apple.com). Without it, the zip is signed but
# not notarized: macOS then asks to allow it once in System Settings > Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${BUBBLE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"Developer ID Application:' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
fi
[ -n "$IDENTITY" ] || { echo "release.sh needs a Developer ID Application identity (or set BUBBLE_SIGN_IDENTITY)" >&2; exit 1; }
export BUBBLE_SIGN_IDENTITY="$IDENTITY"

scripts/build-app.sh release
APP=build/Bubble.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

codesign --force --options runtime --timestamp \
  --entitlements Resources/Bubble.entitlements \
  --identifier local.bubble.Bubble --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

OUT=build/release
ZIP="$OUT/Bubble-$VERSION.zip"
rm -rf "$OUT"; mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute -vv "$APP"
  NOTARIZED=yes
else
  NOTARIZED=no
fi

(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "built $ZIP (version $VERSION, $(du -h "$ZIP" | cut -f1), notarized: $NOTARIZED, signed: $IDENTITY)"
