#!/bin/zsh
# Parser/transport test executable only: never launches JARVIS or Robot Console.
set -euo pipefail
ROOT="${0:A:h:h:h}"
OUT="$ROOT/build/robot-channel-2026-11-09"
mkdir -p "$OUT"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path /private/tmp/jarvis-channel-module-cache \
 "$ROOT/Sources/JARVIS/Robotics/RobotVoiceCommand.swift" \
 "$ROOT/Sources/JARVIS/Robotics/RobotOperatorChannel.swift" \
 "$ROOT/tests/robot_channel/Tests.swift" -o "$OUT/channel-tests"
"$OUT/channel-tests" "$@"
