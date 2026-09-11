#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
export EBURON_ROOT="$ROOT"
red(){ printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
blue(){ printf '\033[36m%s\033[0m\n' "$*"; }
warn(){ printf '\033[33m%s\033[0m\n' "$*"; }
case "${PREFIX:-}" in *com.termux*) ;; *) red 'Run this installer inside Termux, not proot Ubuntu.'; exit 1;; esac
case "$(uname -m)" in aarch64|arm64) ;; *) red 'Android ARM64 only.'; exit 1;; esac
mkdir -p "$ROOT" "$ROOT/logs" "$ROOT/run" "$ROOT/models" "$ROOT/translator"
exec > >(tee -a "$ROOT/logs/install.log") 2>&1
trap 'red "Install failed at line $LINENO. OFFLINE READY was not issued."; [ -x "$ROOT/status.sh" ] && "$ROOT/status.sh" || true' ERR

blue 'Eburon Edge v0.4.0 — audited local voice translator installer'
blue 'Internet is required only for initial provisioning.'

pkg update -y >/dev/null
pkg install -y git cmake ninja clang make python python-pip python-numpy python-onnxruntime \
  curl ffmpeg libsndfile libffi coreutils tar espeak deno >/dev/null
command -v deno >/dev/null || { red 'Deno package is unavailable in this Termux installation.'; exit 1; }
deno --version | head -n 1

[ -x "$ROOT/stop.sh" ] && "$ROOT/stop.sh" >/dev/null 2>&1 || true
sleep 1

# Refresh canonical application files while preserving large downloaded models
# and translator vendor assets across repair installs.
for dir in config gateway public scripts; do rm -rf "$ROOT/$dir"; cp -a "$SELF/$dir" "$ROOT/$dir"; done
mkdir -p "$ROOT/translator"
cp "$SELF/translator/server.mjs" "$ROOT/translator/server.mjs"
rm -rf "$ROOT/translator/node_modules" 2>/dev/null || true
for file in start.sh stop.sh status.sh; do cp "$SELF/$file" "$ROOT/$file"; done
chmod +x "$ROOT"/*.sh "$ROOT/scripts"/*.sh

if [ -n "${EBURON_PACKAGE_REF:-}" ]; then
  EBURON_PACKAGE_REF="$EBURON_PACKAGE_REF" EBURON_ROOT="$ROOT" python - <<'PY'
import json, os, pathlib
root=pathlib.Path(os.environ['EBURON_ROOT'])
p=root/'config'/'release.json'
d=json.loads(p.read_text())
d['package_ref']=os.environ['EBURON_PACKAGE_REF']
p.write_text(json.dumps(d,indent=2)+'\n')
PY
fi
source "$ROOT/config/eburon.env"

blue '[1/6] whisper.cpp STT'
"$ROOT/scripts/build_whisper.sh"
"$ROOT/scripts/download_whisper_model.sh"

blue '[2/6] M2M100 translation-only — Deno + Transformers.js Web/WASM'
"$ROOT/scripts/install_translator.sh"
"$ROOT/scripts/test_translator.sh"
rm -f "$ROOT/bin/llama-server" "$ROOT/models/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf" 2>/dev/null || true

blue '[3/6] localhost gateway'
rm -rf "$ROOT/venv-gateway"
python -m venv --system-site-packages "$ROOT/venv-gateway"
"$ROOT/venv-gateway/bin/pip" -q install -U pip wheel setuptools
"$ROOT/venv-gateway/bin/pip" -q install -r "$ROOT/gateway/requirements.txt"
"$ROOT/venv-gateway/bin/python" - <<'PY'
import starlette,uvicorn,httpx,websockets,multipart
print('  ✓ gateway runtime ready')
PY

blue '[4/6] Supertonic 3 primary TTS'
python - <<'PY'
import onnxruntime as ort
p=ort.get_available_providers()
print('  ✓ ONNX Runtime',ort.__version__,p)
assert p
PY
rm -rf "$ROOT/venv-tts"
python -m venv --system-site-packages "$ROOT/venv-tts"
"$ROOT/venv-tts/bin/pip" -q install -U pip wheel setuptools
"$ROOT/venv-tts/bin/pip" -q install soundfile==0.13.1 starlette==0.48.0 uvicorn==0.35.0
"$ROOT/venv-tts/bin/pip" -q install --no-deps 'git+https://github.com/supertone-oss-archive/supertonic-py.git@df0f9686dac7fbbde391b759e2ee5286a3737622'
MODEL="$ROOT/models/supertonic-3"
mkdir -p "$MODEL/onnx" "$MODEL/voice_styles"
BASE='https://huggingface.co/Supertone/supertonic-3/resolve/724fb5abbf5502583fb520898d45929e62f02c0b'
dl(){ local r="$1" d="$MODEL/$1"; [ -s "$d" ] && return; mkdir -p "$(dirname "$d")"; rm -f "$d.part"; curl -fLsS --retry 8 --retry-delay 3 --retry-all-errors "$BASE/$r?download=true" -o "$d.part"; mv "$d.part" "$d"; }
for f in duration_predictor.onnx text_encoder.onnx vector_estimator.onnx vocoder.onnx tts.json unicode_indexer.json; do dl "onnx/$f"; done
for v in F1 F2 F3 F4 F5 M1 M2 M3 M4 M5; do dl "voice_styles/$v.json"; done
SUPERTONIC_MODEL_DIR="$MODEL" "$ROOT/venv-tts/bin/python" - <<'PY'
import os,soundfile as sf
from supertonic import TTS
t=TTS(model_dir=os.environ['SUPERTONIC_MODEL_DIR'],auto_download=False)
a,_=t.synthesize('Eburon local voice verification.',voice_style=t.get_voice_style(voice_name='M1'),total_steps=2,speed=1.05,lang='en')
p=os.path.join(os.environ['EBURON_ROOT'],'logs','install-supertonic.wav')
sf.write(p,a.squeeze(),t.sample_rate)
assert os.path.getsize(p)>1000
print('  ✓ Supertonic synthesis verified')
PY

blue '[5/6] optional TTS metadata'
mkdir -p "$ROOT/models/piper"
curl -fLsS --retry 4 --retry-delay 2 --retry-all-errors \
  'https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json?download=true' \
  -o "$ROOT/models/piper/voices.json" || true
warn '  ! Piper synthesis remains disabled until an isolated Android runtime is verified.'
warn '  ! Kokoro remains optional/disabled.'

blue '[6/6] boot + real end-to-end verification'
"$ROOT/scripts/install_boot.sh"
"$ROOT/stop.sh" >/dev/null 2>&1 || true
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
