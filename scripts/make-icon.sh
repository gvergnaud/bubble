#!/bin/bash
# Owner: QA track. Regenerates Resources/AppIcon.icns from scripts/make-icon.swift (iconutil, no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."
SET=build/AppIcon.iconset
rm -rf "$SET"; mkdir -p build
swift scripts/make-icon.swift "$SET" >/dev/null
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
