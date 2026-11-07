#!/bin/bash
# Owner: QA track. Builds build/Bubble.app from SwiftPM and signs it (docs/architecture.md §4, §7).
#   scripts/build-app.sh [debug|release] [--install]
# Signing identity: $BUBBLE_SIGN_IDENTITY, else the first "Developer ID Application" or
# "Apple Development" identity in the keychain, else ad-hoc (the Screen Recording grant then
# breaks at each rebuild: tccutil reset ScreenCapture local.bubble.Bubble).
# --install copies the app to ~/Applications/Bubble.app (the stable place for daily use).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG=$arg ;;
    --install) INSTALL=1 ;;
    *) echo "usage: scripts/build-app.sh [debug|release] [--install]" >&2; exit 2 ;;
  esac
done

swift build -c "$CONFIG" --product Bubble
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Bubble"

ICNS=Resources/AppIcon.icns
if [ ! -f "$ICNS" ]; then scripts/make-icon.sh; fi

APP=build/Bubble.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bubble"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
# The editor page (docs/editor-architecture.md §1): served by Bubble from Resources/editor/.
# Its tests stay out of the app.
if [ -d web/editor ]; then
  rsync -a --delete --exclude 'test/' --exclude '.DS_Store' web/editor/ "$APP/Contents/Resources/editor/"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint -s "$APP/Contents/Info.plist"

IDENTITY="${BUBBLE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Developer ID Application|Apple Development):' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [ -z "$IDENTITY" ]; then
  echo "warning: no signing identity found, signing ad-hoc: the Screen Recording grant will not survive a rebuild" >&2
  IDENTITY=-
fi
# The first signing with a Developer ID key can show a keychain prompt ("codesign wants to use
# your key"): answer Always Allow once, or the build waits for it.
SIGN_RC=0
SIGN_OUT=$(codesign --force --sign "$IDENTITY" --identifier local.bubble.Bubble "$APP" 2>&1) || SIGN_RC=$?
if ! codesign --verify --strict "$APP"; then
  echo "codesign failed (rc $SIGN_RC) with identity '$IDENTITY':" >&2
  echo "$SIGN_OUT" >&2
  exit 1
fi
echo "built $APP ($CONFIG, signed: $IDENTITY)"

if [ "$INSTALL" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Bubble.app"
  cp -R "$APP" "$HOME/Applications/Bubble.app"
  echo "installed $HOME/Applications/Bubble.app"
fi
