#!/bin/zsh
# Live frame-pacing test: opens a window for about 25 s, then prints frames shown per state.
# GPU_LOAD=1 ./tests/reactor_sphere/live.sh adds a GPU load like speech synthesis.
set -euo pipefail
ROOT="${0:A:h:h:h}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-sphere-live.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cat "$ROOT/Sources/JARVIS/HUD/Reactor.swift" "$ROOT/tests/reactor_sphere/LiveMain.swiftpart" > "$WORK/Live.swift"
xcrun swiftc -O -swift-version 5 -D SPHERE_HARNESS -target arm64-apple-macosx14.0 \
    "$ROOT/tests/reactor_sphere/TestSupport.swift" "$WORK/Live.swift" -o "$WORK/live"
"$WORK/live"
