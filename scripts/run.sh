#!/bin/bash
# Owner: QA track. Builds build/Bubble.app, quits the running Bubble, opens the new one.
#   scripts/run.sh [debug|release]
#   BUBBLE_FAKE=1 scripts/run.sh   -> the app wires FakeRecorder & co: nothing is captured.
# Logs: log stream --predicate 'subsystem == "local.bubble.Bubble"'
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh "${1:-debug}"

# Quit the running copy (ours only, by bundle id), then make sure it is gone.
osascript -e 'tell application id "local.bubble.Bubble" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  pgrep -f '/Bubble.app/Contents/MacOS/Bubble$' >/dev/null || break
  sleep 0.25
done
if pids=$(pgrep -f '/Bubble.app/Contents/MacOS/Bubble$'); then kill $pids 2>/dev/null || true; fi

# `open --env` passes BUBBLE_FAKE through LaunchServices.
ENV_ARGS=()
if [ -n "${BUBBLE_FAKE:-}" ]; then ENV_ARGS=(--env "BUBBLE_FAKE=$BUBBLE_FAKE"); fi
open -n ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} build/Bubble.app
echo "opened build/Bubble.app${BUBBLE_FAKE:+ (BUBBLE_FAKE=$BUBBLE_FAKE)}"
