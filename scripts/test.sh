#!/bin/bash
# Runs `swift test`. With only the Command Line Tools (no Xcode), Swift Testing needs these paths.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$CLT/Frameworks/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  F="$CLT/Frameworks"; L="$CLT/usr/lib"
  exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
