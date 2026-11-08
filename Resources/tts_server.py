"""Local speech synthesis service for JARVIS: Qwen3 in Italian, Kokoro in English.

Started by the app with the venv interpreter in
~/Library/Application Support/JARVIS/tts/.venv. Listens on 127.0.0.1, on a port
chosen by the system, and writes it to stdout ("PORT 12345") as soon as it is ready.

POST /synth  {"text": ..., "voice": "bm_lewis", "lang": "en-gb", "speed": 1.0}
  "voice" can also be a blend: "im_nicola:0.5+bm_fable:0.5"
  "voice": "qwen3" uses Qwen3 with the voice of voce_jarvis.wav; if it fails it falls back to
  Supertonic ("supertonic:M4:0.5+M3:0.5") and then to "fallback", a Kokoro voice.
  "keep": true saves the audio to disk: used for acknowledgments, fixed sentences to say at once.
  "onlySaved": true returns only an already saved audio, without generating anything.
  -> PCM float32 little-endian audio, mono, 24000 Hz

POST /embed  body: PCM float32 little-endian audio, mono, 16000 Hz
  -> voiceprint (float32 little-endian), to recognise who is speaking.
  The audio is not saved.

Quits by itself when the app that started it exits.
"""

import hashlib
import json
import os
import queue
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from kokoro_onnx import Kokoro

HERE = os.path.expanduser("~/Library/Application Support/JARVIS/tts")
kokoro = Kokoro(os.path.join(HERE, "kokoro-v1.0.onnx"), os.path.join(HERE, "voices-v1.0.bin"))
lock = threading.Lock()
TOKEN = os.environ.get("JARVIS_TTS_TOKEN", "")


# Voiceprint (optional): if something is missing JARVIS's voice works anyway.
try:
    import sherpa_onnx

    speaker = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=os.path.join(HERE, "nemo_en_titanet_small.onnx"), num_threads=2))
except Exception:  # noqa: BLE001
    speaker = None


def embed(body):
    if speaker is None:
        raise RuntimeError("modello dell'impronta vocale non disponibile")
    samples = np.frombuffer(body, dtype="<f4")
    if not 1600 <= len(samples) <= 16000 * 30:
        raise ValueError("durata non valida")
    with lock:
        stream = speaker.create_stream()
        stream.accept_waveform(16000, samples)
        stream.input_finished()
        return np.asarray(speaker.compute(stream), dtype="<f4").tobytes()


# The models are already here: never online.
os.environ["HF_HUB_OFFLINE"] = "1"

# Qwen3 Italian voice (optional). It works entirely in its own thread: MLX wants a single
# thread, and the speaker voice check must not wait for a sentence to finish.
QWEN_DIR = os.path.join(HERE, "qwen3")
QWEN_VOICE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voce_jarvis.wav")
QWEN_VOICE_TEXT = ("Subito, signore. Ho completato il controllo: tutti i sistemi sono operativi "
                   "e possiamo procedere con il volo di prova quando desidera.")
QWEN_CLIPS = os.path.join(HERE, "conferme")
SUPERTONIC_VOICE = "M4:0.5+M3:0.5"
qwen_jobs = queue.Queue()
qwen_ready = threading.Event()
qwen_broken = not (os.path.exists(os.path.join(QWEN_DIR, "config.json")) and os.path.exists(QWEN_VOICE))


def qwen_worker():
    global qwen_broken
    try:
        import mlx.core as mx
        import soundfile
        from mlx_audio.tts.utils import load

        model = load(QWEN_DIR)
        reference = mx.array(soundfile.read(QWEN_VOICE, dtype="float32")[0])

        def generate(text, speed):
            parts = model.generate(text=text, ref_audio=reference, ref_text=QWEN_VOICE_TEXT,
                                   lang_code="italian", speed=speed, verbose=False)
            samples = np.concatenate([np.asarray(part.audio).squeeze() for part in parts])
            mx.clear_cache()
            return samples

        generate("Pronto.", 1.0)
    except Exception:  # noqa: BLE001
        qwen_broken = True
        qwen_ready.set()
        return
    qwen_ready.set()
    while True:
        text, speed, job = qwen_jobs.get()
        try:
            job["audio"] = np.asarray(trim_silence(generate(text, speed), 24000), dtype="<f4").tobytes()
        except Exception as error:  # noqa: BLE001
            job["error"] = error
        job["done"].set()


def saved_clip_path(text, speed):
    key = f"{os.path.getsize(QWEN_VOICE)}|{speed}|{text}"
    return os.path.join(QWEN_CLIPS, hashlib.sha256(key.encode()).hexdigest() + ".pcm")


def saved_clip(text, speed):
    with open(saved_clip_path(text, speed), "rb") as file:
        return file.read()


def synth_qwen(text, speed, keep):
    clip = None
    if keep:
        clip = saved_clip_path(text, speed)
        if os.path.exists(clip):
            return saved_clip(text, speed)
    spoken = italian_speech(text)
    if not spoken or not qwen_ready.wait(60) or qwen_broken:
        raise RuntimeError("Qwen3 non disponibile")
    job = {"done": threading.Event()}
    qwen_jobs.put((spoken, speed, job))
    if not job["done"].wait(80):
        raise RuntimeError("Qwen3 non ha risposto")
    if "error" in job:
        raise job["error"]
    if clip:
        os.makedirs(QWEN_CLIPS, exist_ok=True)
        with open(clip, "wb") as file:
            file.write(job["audio"])
    return job["audio"]


# Qwen3 fallback: it loads only when needed, so it takes no memory.
supertonic = None
supertonic_failed = False
supertonic_styles = {}


def load_supertonic():
    global supertonic, supertonic_failed
    if supertonic is None and not supertonic_failed:
        try:
            from supertonic import TTS

            supertonic = TTS(model_dir=os.path.join(HERE, "supertonic"), auto_download=False)
        except Exception:  # noqa: BLE001
            supertonic_failed = True
    return supertonic


UNITS = {"%": "per cento", "€": "euro", "$": "dollari", "£": "sterline", "°C": "gradi", "°": "gradi",
         "kg": "chili", "km": "chilometri", "cm": "centimetri", "mm": "millimetri", "GB": "gigabyte",
         "MB": "megabyte", "TB": "terabyte", "kHz": "chilohertz", "Hz": "hertz", "mAh": "milliampere ora",
         "V": "volt", "W": "watt"}
ONES = ["zero", "uno", "due", "tre", "quattro", "cinque", "sei", "sette", "otto", "nove", "dieci", "undici",
        "dodici", "tredici", "quattordici", "quindici", "sedici", "diciassette", "diciotto", "diciannove"]
TENS = ["", "", "venti", "trenta", "quaranta", "cinquanta", "sessanta", "settanta", "ottanta", "novanta"]


def number_words(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        tens, unit = divmod(n, 10)
        word = TENS[tens]
        if unit in (1, 8):
            word = word[:-1]
        return word + ("tré" if unit == 3 else ONES[unit] if unit else "")
    if n < 1000:
        hundreds, rest = divmod(n, 100)
        word = ("" if hundreds == 1 else ONES[hundreds]) + "cento"
        if rest // 10 == 8:
            word = word[:-1]
        return word + (number_words(rest) if rest else "")
    if n < 1000000:
        thousands, rest = divmod(n, 1000)
        word = "mille" if thousands == 1 else number_words(thousands) + "mila"
        return word + (" " + number_words(rest) if rest else "")
    if n < 1000000000:
        millions, rest = divmod(n, 1000000)
        word = "un milione" if millions == 1 else number_words(millions) + " milioni"
        return word + (" " + number_words(rest) if rest else "")
    return " ".join(ONES[int(c)] for c in str(n))


def digits_words(digits):
    return " ".join(ONES[int(c)] for c in digits) if digits.startswith("0") and len(digits) > 1 else number_words(int(digits))


def italian_speech(text):
    """Numbers and symbols as words: Supertonic alone misreads them ("149,99 €" became "59,99")."""
    t = re.sub(r"\b(\d{1,2}):(\d{2})\b",
               lambda m: number_words(int(m[1])) + (" e " + number_words(int(m[2])) if m[2] != "00" else ""), text)
    t = re.sub(r"\b(\d{1,3}(?:\.\d{3})+)\b", lambda m: m[1].replace(".", ""), t)
    t = re.sub(r"([€$£])\s?(\d+(?:,\d+)?)", r"\2 \1", t)
    units = "|".join(sorted(map(re.escape, UNITS), key=len, reverse=True))
    t = re.sub(r"(\d)\s?(" + units + r")(?![A-Za-zÀ-ÿ])", lambda m: m[1] + " " + UNITS[m[2]], t)
    t = re.sub(r"\b(\d+)[,.](\d+)\b",
               lambda m: digits_words(m[1]) + " virgola "
               + (number_words(int(m[2])) if len(m[2]) == 2 and m[2][0] != "0" else " ".join(ONES[int(c)] for c in m[2])), t)
    t = re.sub(r"\d+", lambda m: digits_words(m[0]), t)
    t = t.replace("C++", "C più più").replace(" & ", " e ").replace("_", " ")
    t = re.sub(r"[^\w\s.,;:!?'’\"«»()\-–—…]", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def supertonic_style(voice):
    """A voice ("M4") or a blend ("M4:0.5+M3:0.5")."""
    from supertonic.core import Style

    if voice not in supertonic_styles:
        ttl = dp = 0
        for part in voice.split("+"):
            name, _, weight = part.partition(":")
            style = supertonic.get_voice_style(voice_name=name.strip())
            ttl = ttl + float(weight or 1) * style.ttl
            dp = dp + float(weight or 1) * style.dp
        supertonic_styles[voice] = Style(ttl, dp)
    return supertonic_styles[voice]


def trim_silence(samples, rate):
    samples = np.asarray(samples, dtype=np.float32).squeeze()
    audible = np.abs(samples) > 0.005
    if audible.any():
        where = np.flatnonzero(audible)
        samples = samples[max(0, where[0] - int(0.02 * rate)):where[-1] + int(0.12 * rate)]
    return samples


def to_app_rate(samples, rate, target=24000):
    """From 44.1 kHz to the 24 kHz the app plays, with a filter that avoids hiss."""
    samples = trim_silence(samples, rate)
    n = np.arange(101) - 50
    cutoff = 0.95 * target / rate
    fir = np.sinc(cutoff * n) * cutoff * np.hamming(101)
    filtered = np.convolve(samples, fir, mode="same")
    count = int(len(filtered) * target / rate)
    return np.interp(np.arange(count) * rate / target, np.arange(len(filtered)), filtered)


def synth_supertonic(text, voice, speed):
    spoken = italian_speech(text)
    if not spoken:
        raise ValueError("testo vuoto")
    with lock:
        samples, _ = supertonic.synthesize(spoken, voice_style=supertonic_style(voice), lang="it", speed=speed)
    return np.asarray(to_app_rate(samples, supertonic.sample_rate), dtype="<f4").tobytes()


def voice_style(voice):
    """A voice ("bm_lewis") or a blend ("im_nicola:0.5+bm_fable:0.5")."""
    if "+" not in voice and ":" not in voice:
        return voice
    style = 0
    for part in voice.split("+"):
        name, _, weight = part.partition(":")
        style = style + float(weight or 1) * kokoro.get_voice_style(name.strip())
    return style


def synth(text, voice, lang, speed, fallback=None, keep=False):
    if voice == "qwen3":
        try:
            return synth_qwen(text, speed, keep)
        except Exception:  # noqa: BLE001
            voice, speed = "supertonic:" + SUPERTONIC_VOICE, 1.2
    if voice.startswith("supertonic:"):
        try:
            if load_supertonic() is None:
                raise RuntimeError("Supertonic non disponibile")
            return synth_supertonic(text, voice.removeprefix("supertonic:"), speed)
        except Exception:  # noqa: BLE001
            if not fallback:
                raise
            voice = fallback
    with lock:
        samples, _ = kokoro.create(text, voice=voice_style(voice), speed=speed, lang=lang)
    return np.asarray(samples, dtype="<f4").tobytes()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        # JARVIS only: right token, no requests from browser web pages.
        host = self.headers.get("Host", "")
        if (self.headers.get("Authorization") != f"Bearer {TOKEN}" or self.headers.get("Origin")
                or not host.startswith(("127.0.0.1:", "localhost:"))):
            self.send_error(403)
            return
        if self.path not in ("/synth", "/embed"):
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            if self.path == "/embed":
                audio = embed(body)
            else:
                req = json.loads(body)
                audio = saved_clip(req["text"], float(req.get("speed", 1.0))) if req.get("onlySaved") else synth(req["text"], req.get("voice", "bm_lewis"), req.get("lang", "en-gb"), float(req.get("speed", 1.0)), req.get("fallback"), bool(req.get("keep")))
        except Exception as error:  # noqa: BLE001 - the error must be returned to the app
            body = str(error).encode()
            self.send_response(500)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(audio)))
        self.end_headers()
        self.wfile.write(audio)

    def log_message(self, *args):
        pass


def watch_parent(parent_pid):
    while True:
        time.sleep(2)
        if os.getppid() != parent_pid:
            os._exit(0)


if __name__ == "__main__":
    threading.Thread(target=watch_parent, args=(os.getppid(),), daemon=True).start()
    # A first dry synthesis: loads everything into memory, so the first real sentence is fast.
    synth("Ready.", "bm_lewis", "en-gb", 1.0)
    if qwen_broken:
        qwen_ready.set()
    else:
        threading.Thread(target=qwen_worker, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(f"PORT {server.server_address[1]}", flush=True)
    server.serve_forever()
