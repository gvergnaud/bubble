#!/bin/bash
# Owner: QA track. The gate (docs/architecture.md §8.1): build, app bundle, unit + engine + UI tests,
# UI snapshots + contact sheet, synthetic writer and crash runs. All on synthetic data: nothing here
# touches the screen, the camera or the mic, and no window is put on screen.
#   scripts/check.sh            -> build/check/summary.txt, build/check/snapshots/index.html, logs
#   BUBBLE_SOAK=1 scripts/check.sh   -> also the 2 h soak test (long)
# Exit code: 0 when every step passed (skipped steps are listed in the summary), 1 otherwise.
set -uo pipefail
cd "$(dirname "$0")/.."
# One run at a time (several agents share this folder and .build): wait up to 15 min for the lock.
LOCK=build/.check.lock
mkdir -p build
for _ in $(seq 1 900); do
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; break; fi
  holder=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$LOCK"; continue; fi   # stale lock
  [ "${waited:-}" ] || { echo "another check.sh (pid $holder) is running: waiting for it…"; waited=1; }
  sleep 1
done
[ -d "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] || { echo "could not get $LOCK"; exit 1; }
trap 'rm -rf "$LOCK"' EXIT
OUT=build/check
rm -rf "$OUT"; mkdir -p "$OUT/snapshots" "$OUT/media"
SUMMARY="$OUT/summary.txt"
FAILED=0
START=$(date +%s)
{ echo "Bubble check, $(date '+%Y-%m-%d %H:%M:%S')"; echo; } > "$SUMMARY"

line() { printf '%-6s %-26s %s\n' "$1" "$2" "$3" | tee -a "$SUMMARY"; }
step() { # step <name> <log> <command...>
  local name=$1 log=$2; shift 2
  local t0=$(date +%s)
  if "$@" > "$OUT/$log" 2>&1; then line PASS "$name" "$(( $(date +%s) - t0 )) s · $OUT/$log"
  else line FAIL "$name" "$(( $(date +%s) - t0 )) s · $OUT/$log"; FAILED=1; tail -25 "$OUT/$log" | sed 's/^/       | /' | tee -a "$SUMMARY"; fi
}

# A piece of the engine still stubbed (fatalError) cannot run: its CLI steps are skipped, not failed.
stubbed() {
  local f; f=$(grep -lE "(class|struct|enum) $1[: {]" -r Sources/BubbleCore/Capture | head -1)
  [ -z "$f" ] || grep -A12 -E "(class|struct|enum) $1[: {]" "$f" | grep -q 'not implemented'
}

# 1. Build everything (app, bubble-diag, libraries).
step build build.log swift build
if [ $FAILED = 1 ]; then echo "build failed: nothing else runs" | tee -a "$SUMMARY"; exit 1; fi

# 2. The app bundle: Info.plist, icon, signature.
step app-bundle build-app.log scripts/build-app.sh debug

# 3. Tests (Swift Testing): core, writer, mixer, crash, AppModel, snapshots.
#    Snapshot tests render offscreen (ImageRenderer) into $BUBBLE_SNAPSHOT_DIR.
export BUBBLE_SNAPSHOT_DIR="$PWD/$OUT/snapshots"
export BUBBLE_DIAG="$PWD/.build/debug/bubble-diag"
export BUBBLE_EDITOR_OUT="$PWD/$OUT/editor/contract-real"
# A hung test (a stalled writer) must not hang the gate: BUBBLE_TEST_TIMEOUT seconds (default 600).
# BUBBLE_TEST_ARGS: extra swift test arguments, e.g. "--skip CaptureSessionTests".
# scripts/with-timeout.pl kills the whole tree on timeout, swiftpm-testing-helper included (it
# leaves the process group and would survive as an orphan, burning CPU and holding the next gates).
with_timeout() { scripts/with-timeout.pl "$@"; }
# shellcheck disable=SC2086
step tests tests.log with_timeout "${BUBBLE_TEST_TIMEOUT:-600}" scripts/test.sh ${BUBBLE_TEST_ARGS:-}
grep -E 'Test run with' "$OUT/tests.log" | tail -1 | sed 's/^/       /' | tee -a "$SUMMARY"
grep -E 'Suite [A-Za-z]+ skipped:' "$OUT/tests.log" | sed -E 's/^.*Suite ([A-Za-z]+) skipped: "?([^"]*)"?.*/\1 (\2)/' | sort -u \
  | sed 's/^/       skipped: /' | tee -a "$SUMMARY"
grep -E '^✘ Test .* recorded an issue' "$OUT/tests.log" | head -20 | sed 's/^/       /' | tee -a "$SUMMARY"

# 4. Synthetic takes through the real writer, checked by decoding every frame.
DIAG=.build/debug/bubble-diag
if stubbed RecordingWriter || stubbed FramePump; then
  line SKIP synthetic-10s "RecordingWriter/FramePump still stubbed (capture track)"
  line SKIP crash-mid-take "RecordingWriter/FramePump still stubbed (capture track)"
else
  synth() { $DIAG synthetic "$OUT/media/static-gaps.mp4" --seconds 10 --static-gaps --fast \
            && $DIAG check "$OUT/media/static-gaps.mp4" --expect-seconds 10; }
  step synthetic-10s synthetic.log synth
  crash() {
    $DIAG synthetic "$OUT/media/crash.mp4" --seconds 20 --crash-after 9 --static-gaps
    local rc=$?
    if [ $rc -lt 128 ]; then echo "expected an abort (rc ≥ 128), got rc=$rc"; return 1; fi
    $DIAG check "$OUT/media/crash.mp4" --min-seconds 7.9
  }
  step crash-mid-take crash.log crash
fi

# 4b. The editor (docs/editor-architecture.md §8): edit model golden cases (page JS), the contract
#     on the mock server, headless Chrome checks of the page (never a window). The contract on the
#     REAL server, its export golden checks and the page on it run inside the tests step above
#     (Tests/BubbleEditorTests/ContractTests.swift → build/check/editor/contract-real/).
EDITOR_OUT="$OUT/editor"; mkdir -p "$EDITOR_OUT"
if command -v node >/dev/null; then
  step editor-model editor-model.log node --test web/test/edits-cases.test.mjs $(ls web/editor/test/*.test.mjs 2>/dev/null)
  MOCK_PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
  node web/mock-server.mjs --port "$MOCK_PORT" > "$EDITOR_OUT/mock-server.log" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$MOCK_PORT/editor/index.html" && break; sleep 0.1; done
  step editor-contract-mock editor-contract-mock.log node web/test/contract.mjs --base "http://127.0.0.1:$MOCK_PORT" --mock --out "$EDITOR_OUT/contract-mock"
  if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
    step editor-page-mock editor-page-mock.log node web/test/page.mjs --base "http://127.0.0.1:$MOCK_PORT" --mock --out "$EDITOR_OUT/page-mock"
  else
    line SKIP editor-page-mock "Google Chrome not installed"
  fi
  kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null
  if [ -f "$EDITOR_OUT/contract-real/contract.txt" ]; then
    line INFO editor-contract-real "$(tail -1 "$EDITOR_OUT/contract-real/contract.txt") · $EDITOR_OUT/contract-real/"
  fi
else
  line SKIP editor "node not installed"
fi

# 5. Soak (opt-in): 2 h at faster than real time.
if [ -n "${BUBBLE_SOAK:-}" ]; then
  step soak-2h soak.log env BUBBLE_SOAK=1 scripts/test.sh --filter SoakTests
else
  line SKIP soak-2h "opt-in: BUBBLE_SOAK=1 scripts/check.sh"
fi

# 6. Contact sheet of the snapshots, for the designer.
N=$(ls "$OUT/snapshots"/*.png 2>/dev/null | wc -l | tr -d ' ')
if [ "$N" -gt 0 ]; then
  scripts/contact-sheet.sh "$OUT/snapshots" > /dev/null
  # A stable copy for review: the next run wipes build/check, not build/review.
  rm -rf build/review/snapshots; mkdir -p build/review; cp -R "$OUT/snapshots" build/review/snapshots
  line PASS snapshots "$N PNG · build/review/snapshots/index.html"
else
  line SKIP snapshots "no PNG written (UI views not landed yet)"
fi

echo | tee -a "$SUMMARY"
if [ $FAILED = 0 ]; then echo "GREEN in $(( $(date +%s) - START )) s" | tee -a "$SUMMARY"
else echo "RED in $(( $(date +%s) - START )) s: see the FAIL lines above" | tee -a "$SUMMARY"; fi
exit $FAILED
