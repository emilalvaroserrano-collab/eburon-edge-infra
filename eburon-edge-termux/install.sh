#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
export EBURON_ROOT="$ROOT"

red(){ printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
blue(){ printf '\033[36m%s\033[0m\n' "$*"; }
warn(){ printf '\033[33m%s\033[0m\n' "$*"; }

case "${PREFIX:-}" in
  *com.termux*) ;;
  *) red 'Run this installer inside Termux, not proot Ubuntu.'; exit 1 ;;
esac
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) red "This release targets Android ARM64 only. Detected: $(uname -m)"; exit 1 ;;
esac

mkdir -p "$ROOT" "$ROOT/logs" "$ROOT/run" "$ROOT/models"
exec > >(tee -a "$ROOT/logs/install.log") 2>&1
fail_report(){
  red "Installation stopped safely at line ${1:-unknown}. OFFLINE READY was not issued."
  [ -x "$ROOT/status.sh" ] && "$ROOT/status.sh" || true
}
trap 'fail_report "$LINENO"' ERR

blue 'Eburon Edge v0.2.0 — clean Android ARM64 appliance installer'
blue 'Internet is required only for this initial provisioning run.'

pkg update -y >/dev/null
pkg install -y git cmake ninja clang make python python-pip python-numpy python-onnxruntime \
  curl ffmpeg libsndfile libffi openssl coreutils tar >/dev/null
if ! pkg install -y nodejs-lts >/dev/null 2>&1; then
  pkg install -y nodejs >/dev/null
fi

if [ -x "$ROOT/stop.sh" ]; then "$ROOT/stop.sh" || true; fi
sleep 1

for dir in config gateway public scripts translator; do
  rm -rf "$ROOT/$dir"
  cp -a "$SELF/$dir" "$ROOT/$dir"
done
for file in start.sh stop.sh status.sh; do cp "$SELF/$file" "$ROOT/$file"; done
chmod +x "$ROOT"/*.sh "$ROOT/scripts"/*.sh

if [ -n "${EBURON_PACKAGE_REF:-}" ]; then
  EBURON_PACKAGE_REF="$EBURON_PACKAGE_REF" python - <<'PY'
import json, os, pathlib
p=pathlib.Path(os.path.expanduser('~/.eburon-edge/config/release.json'))
data=json.loads(p.read_text())
data['package_ref']=os.environ['EBURON_PACKAGE_REF']
p.write_text(json.dumps(data,indent=2)+"\n")
PY
fi

source "$ROOT/config/eburon.env"

blue '[1/6] whisper.cpp STT'
"$ROOT/scripts/build_whisper.sh"
"$ROOT/scripts/download_whisper_model.sh"

blue '[2/6] M2M100 translation-only WASM runtime'
mkdir -p "$ROOT/translator/vendor" "$ROOT/models/m2m100-cache"
TF_TGZ="$ROOT/logs/transformers-4.2.0.tgz"
ORT_TGZ="$ROOT/logs/onnxruntime-web-1.26.0-dev.20260416-b7804b056c.tgz"
TF_VENDOR="$ROOT/translator/vendor/transformers"
ORT_VENDOR="$ROOT/translator/vendor/onnxruntime-web"
TF_SRI='8BRCoBMH0XsWaEIamuR0LrJGAfftgHAfb2Vrffy0VKlSAE/MnUJ5/h/zTfEP3fDIft+nk7TqB8xXEyABGitBjQ=='
ORT_SRI='MD6Ss4GSpQBo6zqoJzyT9LRbKYs7x/JVN23FT24EcEvlqF4VuzPOeH6X38orZPKHQDbprn7K+SBpu0/mj2CQiw=='
verify_sha512_sri(){
  local file="$1" expected="$2" actual
  actual="$(openssl dgst -sha512 -binary "$file" | base64 | tr -d '\n')"
  [ "$actual" = "$expected" ] || { red "Integrity check failed: $file"; return 1; }
}

curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors \
  'https://registry.npmjs.org/@huggingface/transformers/-/transformers-4.2.0.tgz' \
  -o "$TF_TGZ"
verify_sha512_sri "$TF_TGZ" "$TF_SRI"
rm -rf "$TF_VENDOR" "$ROOT/translator/vendor/package"
tar -xzf "$TF_TGZ" -C "$ROOT/translator/vendor"
mv "$ROOT/translator/vendor/package" "$TF_VENDOR"
test -s "$TF_VENDOR/dist/transformers.js"

curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors \
  'https://registry.npmjs.org/onnxruntime-web/-/onnxruntime-web-1.26.0-dev.20260416-b7804b056c.tgz' \
  -o "$ORT_TGZ"
verify_sha512_sri "$ORT_TGZ" "$ORT_SRI"
rm -rf "$ORT_VENDOR" "$ROOT/translator/vendor/package"
tar -xzf "$ORT_TGZ" -C "$ROOT/translator/vendor"
mv "$ROOT/translator/vendor/package" "$ORT_VENDOR"
find "$ORT_VENDOR/dist" -maxdepth 1 -type f -name '*.wasm' -size +100k | grep -q .
echo '  ✓ Transformers.js + local ONNX Runtime Web assets installed (no onnxruntime-node)'

translator_probe(){
  local offline="$1" label="$2" pid result
  : > "$ROOT/logs/translator-install.log"
  (
    cd "$ROOT/translator"
    EBURON_TRANSLATOR_PORT="$EBURON_TRANSLATOR_PORT" \
    EBURON_TRANSLATOR_CACHE="$ROOT/models/m2m100-cache" \
    EBURON_OFFLINE="$offline" M2M_MODEL="$M2M_MODEL" M2M_REVISION="$M2M_REVISION" \
      exec node server.mjs
  ) >>"$ROOT/logs/translator-install.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 40); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/health" >/dev/null 2>&1; then break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.5
  done
  if ! curl -fsS --max-time 3 "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/health" >/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    red "Translator process failed during $label."
    tail -n 80 "$ROOT/logs/translator-install.log" || true
    return 1
  fi
  if ! curl -fsS -X POST --max-time 600 "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/warmup" >/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    red "Translator model warm-up failed during $label."
    tail -n 100 "$ROOT/logs/translator-install.log" || true
    return 1
  fi
  result="$(curl -fsS --max-time 180 -H 'content-type: application/json' \
    -d '{"text":"Good morning.","source_language":"en","target_language":"nl"}' \
    "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/v1/translate")"
  if ! printf '%s' "$result" | grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+'; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    red "Translator inference returned no text during $label: $result"
    return 1
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "  ✓ $label"
}

translator_probe 0 'online model cache warm-up'
translator_probe 1 'offline-cache translation verification'
rm -f "$ROOT/models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf" "$ROOT/bin/llama-server" 2>/dev/null || true

blue '[3/6] localhost gateway'
rm -rf "$ROOT/venv-gateway"
python -m venv --system-site-packages "$ROOT/venv-gateway"
"$ROOT/venv-gateway/bin/pip" -q install -U pip wheel setuptools
"$ROOT/venv-gateway/bin/pip" -q install -r "$ROOT/gateway/requirements.txt"
"$ROOT/venv-gateway/bin/python" - <<'PY'
import starlette, uvicorn, httpx, websockets, multipart
print('  ✓ gateway Python runtime ready')
PY

blue '[4/6] Supertonic 3 primary TTS'
python - <<'PY'
import onnxruntime as ort
providers=ort.get_available_providers()
print('  ✓ Termux ONNX Runtime providers:', providers)
if not providers:
    raise SystemExit('No ONNX Runtime provider available')
PY
rm -rf "$ROOT/venv-tts"
python -m venv --system-site-packages "$ROOT/venv-tts"
"$ROOT/venv-tts/bin/pip" -q install -U pip wheel setuptools
"$ROOT/venv-tts/bin/pip" -q install soundfile==0.13.1 starlette==0.48.0 uvicorn==0.35.0
"$ROOT/venv-tts/bin/pip" -q install --no-deps \
  'git+https://github.com/supertone-oss-archive/supertonic-py.git@df0f9686dac7fbbde391b759e2ee5286a3737622'

MODEL_DIR="$ROOT/models/supertonic-3"
mkdir -p "$MODEL_DIR/onnx" "$MODEL_DIR/voice_styles"
SUPERTONIC_BASE='https://huggingface.co/Supertone/supertonic-3/resolve/724fb5abbf5502583fb520898d45929e62f02c0b'
download_supertonic(){
  local rel="$1" dest="$MODEL_DIR/$1"
  [ -s "$dest" ] && return 0
  mkdir -p "$(dirname "$dest")"
  curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors \
    "$SUPERTONIC_BASE/$rel?download=true" -o "$dest.part"
  mv "$dest.part" "$dest"
}
for file in duration_predictor.onnx text_encoder.onnx vector_estimator.onnx vocoder.onnx tts.json unicode_indexer.json; do
  download_supertonic "onnx/$file"
done
for voice in F1 F2 F3 F4 F5 M1 M2 M3 M4 M5; do
  download_supertonic "voice_styles/$voice.json"
done
SUPERTONIC_MODEL_DIR="$MODEL_DIR" "$ROOT/venv-tts/bin/python" - <<'PY'
import os, soundfile as sf
from supertonic import TTS
tts=TTS(model_dir=os.environ['SUPERTONIC_MODEL_DIR'],auto_download=False)
audio,_=tts.synthesize('Eburon local voice verification.',voice_style=tts.get_voice_style(voice_name='M1'),total_steps=2,speed=1.05,lang='en')
out=os.path.expanduser('~/.eburon-edge/logs/install-supertonic.wav')
sf.write(out,audio.squeeze(),tts.sample_rate)
if os.path.getsize(out) <= 1000:
    raise SystemExit('Supertonic verification WAV is empty')
print('  ✓ Supertonic synthesis verified')
PY

blue '[5/6] optional TTS metadata'
mkdir -p "$ROOT/models/piper"
if curl -fLsS --retry 4 --retry-delay 2 --retry-all-errors \
  'https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json?download=true' \
  -o "$ROOT/models/piper/voices.json"; then
  echo '  ✓ Piper voice catalogue cached'
else
  warn '  ! Piper catalogue unavailable; core translator is unaffected.'
fi
warn '  ! Piper native runtime intentionally not installed: it must not overwrite Termux libonnxruntime.so.'
warn '  ! Kokoro provider disabled until its Android runtime passes the same offline acceptance tests.'

blue '[6/6] boot launcher + full end-to-end verification'
"$ROOT/scripts/install_boot.sh"
"$ROOT/stop.sh" || true
"$ROOT/start.sh"
"$ROOT/scripts/smoke_test.sh"

green '=================================================='
green ' EBURON EDGE: OFFLINE READY'
green ' STT        PASS'
green ' TRANSLATOR PASS'
green ' SUPERTONIC PASS'
green ' WEBSOCKET  PASS'
green ' FRONTEND   PASS'
green '=================================================='
termux-open-url 'http://127.0.0.1:8850' 2>/dev/null || true
