#!/bin/zsh
# Builds JARVIS and creates build/JARVIS.app.
#   ./scripts/build.sh            builds and assembles the app
#   ./scripts/build.sh --install  also copies it to /Applications and launches it
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/JARVIS.app"
cd "$ROOT"
# This Mac's app bundle identifier (local.env, outside Git; example in local.env.example).
[[ -f "$ROOT/local.env" ]] && source "$ROOT/local.env"
BUNDLE_ID="${JARVIS_BUNDLE_ID:-com.example.jarvis}"

echo "▸ Compilazione (release)…"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

echo "▸ Icona…"
ICON_DIR="$ROOT/build/icon"
if [[ ! -f "$ROOT/build/AppIcon.icns" || "$ROOT/scripts/make_icon.swift" -nt "$ROOT/build/AppIcon.icns" ]]; then
    rm -rf "$ICON_DIR" && mkdir -p "$ICON_DIR/AppIcon.iconset"
    swift "$ROOT/scripts/make_icon.swift" "$ICON_DIR/icon_1024.png" >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi

echo "▸ Pacchetto .app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/porcupine"
cp "$BIN/JARVIS" "$APP/Contents/MacOS/JARVIS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT"/Vendor/porcupine/{libpv_porcupine.dylib,porcupine_params.pv,jarvis_mac.ppn} "$APP/Contents/Resources/porcupine/"
cp "$ROOT/Resources/tts_server.py" "$APP/Contents/Resources/tts_server.py"
cp "$ROOT/Resources/voce_jarvis.wav" "$APP/Contents/Resources/voce_jarvis.wav"
cp "$ROOT/Resources/ros_bridge.py" "$APP/Contents/Resources/ros_bridge.py"

echo "▸ Firma…"
# A stable signature lets macOS remember permissions (microphone, Mail…) between builds.
# Without a valid certificate the signature would be "ad hoc", different at every build, and macOS
# would ask for every permission again: better to stop and say so.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -z "$IDENTITY" ]]; then
    if [[ "${JARVIS_ADHOC_SIGN:-}" == "1" ]]; then
        IDENTITY="-"
        echo "  ⚠︎ firma ad hoc: macOS chiederà di nuovo i permessi"
    else
        echo "✗ Certificato Apple Development non trovato o scaduto (Xcode › Impostazioni › Account)." >&2
        echo "  Senza, macOS richiederebbe tutti i permessi. Per firmare comunque: JARVIS_ADHOC_SIGN=1 $0 $*" >&2
        exit 1
    fi
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/porcupine/libpv_porcupine.dylib"
codesign --force --sign "$IDENTITY" --entitlements "$ROOT/Resources/JARVIS.entitlements" "$APP"
echo "  firmata con: $IDENTITY ($BUNDLE_ID)"

if [[ "${1:-}" == "--install" ]]; then
    echo "▸ Installazione in /Applications…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/JARVIS.app
    cp -R "$APP" /Applications/JARVIS.app
    open /Applications/JARVIS.app
fi
echo "✓ Pronto: $APP"
