#!/bin/bash
# Owner: QA track. Writes <dir>/index.html: every <state>-light.png next to its <state>-dark.png,
# for the designer's review. Usage: scripts/contact-sheet.sh build/check/snapshots
set -euo pipefail
DIR=${1:-build/check/snapshots}
OUT="$DIR/index.html"
{
cat <<'HTML'
<!doctype html><meta charset="utf-8"><title>Bubble UI snapshots</title>
<style>
 body{font:14px -apple-system,system-ui;margin:24px;background:#f4f4f6;color:#222}
 h1{font-size:20px} .meta{color:#666;margin-bottom:24px}
 .state{background:#fff;border-radius:10px;padding:14px 16px;margin:0 0 18px;box-shadow:0 1px 3px #0002}
 .state h2{font:600 14px ui-monospace,Menlo;margin:0 0 10px}
 .pair{display:flex;gap:16px;flex-wrap:wrap;align-items:flex-start}
 figure{margin:0} figcaption{color:#888;font-size:12px;margin-top:4px}
 .light img{background:#e9e9ec} .dark img{background:#1e1e20}
 img{display:block;border-radius:6px;max-width:100%;image-rendering:auto}
</style>
<h1>Bubble UI snapshots</h1>
HTML
echo "<div class=meta>$(date '+%Y-%m-%d %H:%M') · @2x PNG, shown at 1x · names: &lt;state&gt;-&lt;light|dark&gt;.png</div>"
for f in $(ls "$DIR"/*.png | sed -E 's#.*/##; s/-(light|dark)\.png$//' | sort -u); do
  echo "<section class=state id=\"$f\"><h2>$f</h2><div class=pair>"
  for mode in light dark; do
    p="$f-$mode.png"
    if [ -f "$DIR/$p" ]; then
      w=$(sips -g pixelWidth "$DIR/$p" | awk '/pixelWidth/{print $2}')
      echo "<figure class=$mode><img src=\"$p\" width=\"$(( w / 2 ))\"><figcaption>$mode</figcaption></figure>"
    fi
  done
  echo "</div></section>"
done
} > "$OUT"
echo "$OUT"
