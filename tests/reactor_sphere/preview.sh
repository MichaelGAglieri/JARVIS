#!/bin/zsh
# Builds a standalone UI preview with synthetic audio meters. Does not launch JARVIS.
set -euo pipefail
ROOT="${0:A:h:h:h}"
APP="$ROOT/build/JARVIS Sphere Preview.app"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-sphere-preview.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$APP/Contents/MacOS"
cat "$ROOT/Sources/JARVIS/HUD/Reactor.swift" "$ROOT/tests/reactor_sphere/PreviewMain.swiftpart" > "$WORK/Preview.swift"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
    "$ROOT/tests/reactor_sphere/TestSupport.swift" "$WORK/Preview.swift" -o "$APP/Contents/MacOS/SpherePreview"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.jarvis.sphere-preview</string>
<key>CFBundleName</key><string>JARVIS Sphere Preview</string>
<key>CFBundleExecutable</key><string>SpherePreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
printf 'Anteprima compilata: %s\n' "$APP"
