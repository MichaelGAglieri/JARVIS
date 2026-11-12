#!/bin/zsh
# Installs JARVIS's neural voices in a Python 3.12 environment: Qwen3 (Italian, ~3.1 GB),
# Kokoro (English, ~350 MB) and Supertonic (Italian fallback, ~390 MB).
set -euo pipefail

TTS="$HOME/Library/Application Support/JARVIS/tts"
MODELS=https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0
mkdir -p "$TTS"
cd "$TTS"

command -v uv >/dev/null || brew install uv
[[ -x .venv/bin/python ]] || uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -q kokoro-onnx soundfile sherpa-onnx "supertonic==1.3.1" "mlx-audio==0.6.1"

[[ -f kokoro-v1.0.onnx ]] || curl -fL -o kokoro-v1.0.onnx "$MODELS/kokoro-v1.0.onnx"
[[ -f voices-v1.0.bin ]] || curl -fL -o voices-v1.0.bin "$MODELS/voices-v1.0.bin"
# Voiceprint: recognises the user's voice (~40 MB).
SPEAKER=https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models
[[ -f nemo_en_titanet_small.onnx ]] || curl -fL -o nemo_en_titanet_small.onnx "$SPEAKER/nemo_en_titanet_small.onnx"
# Italian voice: downloads the official Supertone/supertonic-3 model.
[[ -f supertonic/onnx/vocoder.onnx ]] || .venv/bin/python -I -c 'import os; from supertonic import TTS; TTS(model_dir=os.path.abspath("supertonic"), auto_download=True)'
# Italian voice: official Qwen3-TTS model for Apple Silicon.
# Italian voice: the small Qwen3 (0.6B), about 40% less GPU work than the 1.7B used until 1.30.18.
[[ -f qwen3-0.6b/config.json ]] || .venv/bin/python -I -c 'from huggingface_hub import snapshot_download; snapshot_download("mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", local_dir="qwen3-0.6b")'
echo "✓ Voci pronte in $TTS"
