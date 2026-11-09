#!/bin/zsh
# Isolated renderer test: no JARVIS launch, audio, network, or user configuration.
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="${1:-$ROOT/build/reactor-validation}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-sphere-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
cat "$ROOT/Sources/JARVIS/HUD/Reactor.swift" "$ROOT/tests/reactor_sphere/TestMain.swiftpart" > "$WORK/Validation.swift"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
    "$ROOT/tests/reactor_sphere/TestSupport.swift" "$WORK/Validation.swift" -o "$WORK/validate"
MTL_DEBUG_LAYER=1 "$WORK/validate" "$OUT" | tee "$OUT/results.txt"
