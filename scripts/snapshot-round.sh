#!/bin/bash
# Owner: QA track. Freezes the latest snapshots (build/review/snapshots, written by check.sh) as the
# next review round: build/review/round-<N>/ (never overwritten or deleted by any script).
#   scripts/snapshot-round.sh [extra.png ...]   -> prints the round folder; extra PNGs are added to it
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=build/review/snapshots
[ -f "$SRC/index.html" ] || { echo "no $SRC/index.html: run scripts/check.sh first" >&2; exit 1; }
# Next number after the highest existing round (gaps are not reused).
N=$(( $(ls -d build/review/round-* 2>/dev/null | sed -E 's/.*round-//' | sort -n | tail -1 || echo 0) + 1 ))
DEST=build/review/round-$N
cp -R "$SRC" "$DEST"
for f in "$@"; do cp "$f" "$DEST/"; done
[ $# -gt 0 ] && scripts/contact-sheet.sh "$DEST" > /dev/null
echo "$PWD/$DEST"
