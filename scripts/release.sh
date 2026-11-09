#!/bin/bash
# Builds the downloadable Bubble: build/release/Bubble-<version>.zip (+ .sha256).
#   scripts/release.sh
# Release build (scripts/build-app.sh release), then signed again with the hardened runtime, a secure
# timestamp and Resources/Bubble.entitlements, which notarization needs. Needs a "Developer ID
# Application" identity ($BUBBLE_SIGN_IDENTITY, else the first one in the keychain).
# Notarization: the zip goes to Apple with the notarytool keychain profile $NOTARY_PROFILE (default
# bubble-notary), made once from an App Store Connect API team key (role Developer):
#   xcrun notarytool store-credentials bubble-notary --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
# The release fails if Apple rejects it (its log is printed). NOTARY_PROFILE= (empty) skips it: the
# zip is then signed but not notarized, and macOS asks to allow it once in System Settings.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTARY_PROFILE="${NOTARY_PROFILE-bubble-notary}"

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

if [ -n "$NOTARY_PROFILE" ]; then
  # Apple scans the zip (a few minutes), then the ticket is stapled into the app so Gatekeeper
  # accepts it offline too. The zip is made again from the stapled app.
  RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  echo "$RESULT"
  SUBMISSION=$(echo "$RESULT" | plutil -extract id raw -o - - 2>/dev/null || true)
  STATUS=$(echo "$RESULT" | plutil -extract status raw -o - - 2>/dev/null || true)
  if [ "$STATUS" != "Accepted" ]; then
    echo "notarization: status '$STATUS' for submission '$SUBMISSION'. Apple's log:" >&2
    [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute -vvv "$APP"
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
  NOTARIZED=yes
else
  echo "warning: NOTARY_PROFILE is empty: the zip is signed but not notarized" >&2
  NOTARIZED=no
fi

(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "built $ZIP (version $VERSION, $(du -h "$ZIP" | cut -f1), notarized: $NOTARIZED, signed: $IDENTITY)"
