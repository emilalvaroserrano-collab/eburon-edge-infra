#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
export EBURON_ROOT="$ROOT"
red(){ printf '\033[31m%s\033[0m\n' "$*"; }
green(){ printf '\033[32m%s\033[0m\n' "$*"; }
blue(){ printf '\033[36m%s\033[0m\n' "$*"; }
warn(){ printf '\033[33m%s\033[0m\n' "$*"; }
case "${PREFIX:-}" in *com.termux*) ;; *) red 'Run this installer inside Termux.'; exit 1;; esac
case "$(uname -m)" in aarch64|arm64) ;; *) red 'Android ARM64 only.'; exit 1;; esac
mkdir -p "$ROOT" "$ROOT/logs" "$ROOT/run" "$ROOT/models"
exec > >(tee -a "$ROOT/logs/install.log") 2>&1
trap 'red "Install failed at line $LINENO. OFFLINE READY was not issued."; [ -x "$ROOT/status.sh" ] && "$ROOT/status.sh" || true' ERR
blue 'Eburon Edge v0.3.2 — final local voice translator installer'
blue 'Internet is required only for initial provisioning.'

pkg update -y >/dev/null
pkg install -y git cmake ninja clang make python python-pip python-numpy python-onnxruntime \
  curl ffmpeg libsndfile libffi coreutils tar espeak >/dev/null
if ! pkg install -y nodejs-lts >/dev/null 2>&1; then pkg install -y nodejs >/dev/null; fi

[ -x "$ROOT/stop.sh" ] && "$ROOT/stop.sh" || true
sleep 1
for dir in config gateway public scripts translator; do rm -rf "$ROOT/$dir"; cp -a "$SELF/$dir" "$ROOT/$dir"; done
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

blue '[2/6] pinned local M2M100 translation engine'
mkdir -p "$ROOT/translator/vendor" "$ROOT/translator/node_modules" "$ROOT/models/m2m100-local"
TF_TGZ="$ROOT/logs/transformers-4.2.0.tgz"
ORT_TGZ="$ROOT/logs/onnxruntime-web.tgz"
TF="$ROOT/translator/vendor/transformers"
ORT="$ROOT/translator/vendor/onnxruntime-web"
verify_sri(){
  local file="$1" expected="$2"
  python - "$file" "$expected" <<'PY'
import base64,hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1]); expected=sys.argv[2]
actual=base64.b64encode(hashlib.sha512(p.read_bytes()).digest()).decode()
if actual != expected:
    raise SystemExit(f'integrity mismatch: {p}')
PY
}

curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors \
  'https://registry.npmjs.org/@huggingface/transformers/-/transformers-4.2.0.tgz' -o "$TF_TGZ"
verify_sri "$TF_TGZ" '8BRCoBMH0XsWaEIamuR0LrJGAfftgHAfb2Vrffy0VKlSAE/MnUJ5/h/zTfEP3fDIft+nk7TqB8xXEyABGitBjQ=='
rm -rf "$TF" "$ROOT/translator/vendor/package"
tar -xzf "$TF_TGZ" -C "$ROOT/translator/vendor"
mv "$ROOT/translator/vendor/package" "$TF"
test -s "$TF/dist/transformers.js"

curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors \
  'https://registry.npmjs.org/onnxruntime-web/-/onnxruntime-web-1.26.0-dev.20260416-b7804b056c.tgz' -o "$ORT_TGZ"
verify_sri "$ORT_TGZ" 'MD6Ss4GSpQBo6zqoJzyT9LRbKYs7x/JVN23FT24EcEvlqF4VuzPOeH6X38orZPKHQDbprn7K+SBpu0/mj2CQiw=='
rm -rf "$ORT" "$ROOT/translator/vendor/package"
tar -xzf "$ORT_TGZ" -C "$ROOT/translator/vendor"
mv "$ROOT/translator/vendor/package" "$ORT"
find "$ORT/dist" -maxdepth 1 -type f -name '*.wasm' -size +100k | grep -q .
ln -sfn ../vendor/onnxruntime-web "$ROOT/translator/node_modules/onnxruntime-web"
echo '  ✓ Transformers.js browser/WASM runtime installed without onnxruntime-node'

M2M_LOCAL_ROOT="$ROOT/models/m2m100-local"
M2M_DIR="$M2M_LOCAL_ROOT/$M2M_MODEL"
M2M_BASE="https://huggingface.co/$M2M_MODEL/resolve/$M2M_REVISION"
mkdir -p "$M2M_DIR/onnx"
download_m2m(){
  local rel="$1" min_bytes="$2" dest="$M2M_DIR/$1" size=0
  if [ -f "$dest" ]; then size="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"; fi
  if [ "$size" -ge "$min_bytes" ]; then echo "  ✓ cached $rel"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  rm -f "$dest.part"
  echo "  ↓ $rel"
  curl -fL --retry 8 --retry-delay 3 --retry-all-errors --connect-timeout 20 \
    "$M2M_BASE/$rel?download=true" -o "$dest.part"
  size="$(stat -c '%s' "$dest.part" 2>/dev/null || echo 0)"
  [ "$size" -ge "$min_bytes" ] || { red "Model file is incomplete: $rel ($size bytes)"; return 1; }
  mv "$dest.part" "$dest"
}
for f in config.json generation_config.json quantize_config.json special_tokens_map.json tokenizer_config.json; do download_m2m "$f" 100; done
download_m2m sentencepiece.bpe.model 2000000
download_m2m tokenizer.json 7000000
download_m2m vocab.json 3000000
download_m2m onnx/encoder_model_quantized.onnx 280000000
download_m2m onnx/decoder_model_merged_quantized.onnx 330000000

echo '  ✓ pinned M2M100 model files are fully local'

probe_translator(){
  local pid out
  : >"$ROOT/logs/translator-install.log"
  (
    cd "$ROOT/translator"
    EBURON_TRANSLATOR_PORT="$EBURON_TRANSLATOR_PORT" \
    M2M_MODEL="$M2M_MODEL" M2M_REVISION="$M2M_REVISION" \
    M2M_LOCAL_ROOT="$M2M_LOCAL_ROOT" \
      exec node server.mjs
  ) >>"$ROOT/logs/translator-install.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 60); do
    curl -fsS --max-time 2 "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/health" >/dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || break
    sleep .5
  done
  curl -fsS --max-time 3 "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/health" >/dev/null || {
    tail -n 120 "$ROOT/logs/translator-install.log" || true; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1;
  }
  curl -fsS -X POST --max-time 900 "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/warmup" >/dev/null || {
    tail -n 160 "$ROOT/logs/translator-install.log" || true; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1;
  }
  out="$(curl -fsS --max-time 240 -H 'content-type: application/json' \
    -d '{"text":"Good morning.","source_language":"en","target_language":"nl"}' \
    "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/v1/translate")"
  printf '%s' "$out" | grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+' || {
    red "Translator returned no text: $out"; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1;
  }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo '  ✓ local M2M100 EN→NL inference verified'
}
probe_translator
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
import onnxruntime as o
p=o.get_available_providers()
print('  ✓ ONNX Runtime',o.__version__,p)
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
dl(){ local r="$1" d="$MODEL/$1"; [ -s "$d" ] && return; mkdir -p "$(dirname "$d")"; curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors "$BASE/$r?download=true" -o "$d.part"; mv "$d.part" "$d"; }
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
warn '  ! Piper synthesis stays disabled until an isolated Android runtime is verified.'
warn '  ! Kokoro remains optional/disabled.'

blue '[6/6] boot + real end-to-end verification'
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
