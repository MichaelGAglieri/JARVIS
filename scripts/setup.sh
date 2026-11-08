#!/bin/zsh
# Installs JARVIS from scratch on an Apple Silicon Mac:
#   Ollama + local model, neural voices, building and installing the app.
# Requires Xcode (or the Command Line Tools) and Homebrew. It can be run again: it skips what is already there.
# Whisper (transcription and the word "Jarvis") downloads by itself on the app's first launch.
set -euo pipefail

ROOT="${0:A:h:h}"
MODEL="gemma4:12b-it-qat"

echo "▸ Ollama…"
command -v ollama >/dev/null || brew install ollama
if ! curl -sf http://localhost:11434/api/tags >/dev/null; then
    (ollama serve >/dev/null 2>&1 &)
    sleep 3
fi
ollama list | grep -q "^$MODEL" || ollama pull "$MODEL"

echo "▸ Voce neurale Kokoro…"
"$ROOT/scripts/setup_tts.sh"

echo "▸ Claude Code (facoltativo, per la modalità Claude)…"
if command -v claude >/dev/null; then
    claude auth status 2>/dev/null | grep -q '"loggedIn": true' || echo "  per usare Claude: claude auth login --claudeai"
else
    echo "  non installato: brew install --cask claude-code (poi claude auth login --claudeai)"
fi

echo "▸ App…"
"$ROOT/scripts/build.sh" --install
echo "✓ JARVIS installato. Al primo avvio concedi il microfono; poi Calendario, Promemoria e Mail quando li usi."
