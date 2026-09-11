#!/usr/bin/env bash
set -euo pipefail

ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
[ -f "$ROOT/config/eburon.env" ] && source "$ROOT/config/eburon.env"
M2M_MODEL="${M2M_MODEL:-huggingworld/m2m100_418M}"
M2M_REVISION="${M2M_REVISION:-48f06c0fec544323fcf1546e312a617d962d3653}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python || command -v python3 || true)}"
[ -n "$PYTHON_BIN" ] || { echo 'ERROR: Python is required for package integrity verification.' >&2; exit 1; }
command -v curl >/dev/null || { echo 'ERROR: curl is required.' >&2; exit 1; }
command -v tar >/dev/null || { echo 'ERROR: tar is required.' >&2; exit 1; }
command -v sha256sum >/dev/null || { echo 'ERROR: sha256sum is required.' >&2; exit 1; }
command -v deno >/dev/null || { echo 'ERROR: Deno runtime is required.' >&2; exit 1; }

mkdir -p "$ROOT/translator/vendor" "$ROOT/models/m2m100-local" "$ROOT/logs"
TF_TGZ="$ROOT/logs/transformers-4.2.0.tgz"
ORT_TGZ="$ROOT/logs/onnxruntime-web-1.26.0-dev.20260416-b7804b056c.tgz"
TF="$ROOT/translator/vendor/transformers"
ORT="$ROOT/translator/vendor/onnxruntime-web"

verify_sri(){
  local file="$1" expected="$2"
  "$PYTHON_BIN" - "$file" "$expected" <<'PY'
import base64, hashlib, pathlib, sys
p=pathlib.Path(sys.argv[1]); expected=sys.argv[2]
actual=base64.b64encode(hashlib.sha512(p.read_bytes()).digest()).decode()
if actual != expected:
    raise SystemExit(f'integrity mismatch: {p}')
PY
}

fetch_pkg(){
  local url="$1" dest="$2" sri="$3"
  curl -fLsS --retry 8 --retry-delay 3 --retry-all-errors --connect-timeout 20 "$url" -o "$dest.part"
  verify_sri "$dest.part" "$sri"
  mv -f "$dest.part" "$dest"
}

if [ ! -s "$TF/dist/transformers.js" ]; then
  echo '  ↓ Transformers.js 4.2.0'
  rm -rf "$TF" "$ROOT/translator/vendor/package"
  fetch_pkg 'https://registry.npmjs.org/@huggingface/transformers/-/transformers-4.2.0.tgz' "$TF_TGZ" '8BRCoBMH0XsWaEIamuR0LrJGAfftgHAfb2Vrffy0VKlSAE/MnUJ5/h/zTfEP3fDIft+nk7TqB8xXEyABGitBjQ=='
  tar -xzf "$TF_TGZ" -C "$ROOT/translator/vendor"
  mv "$ROOT/translator/vendor/package" "$TF"
fi
[ -s "$TF/dist/transformers.js" ] || { echo 'ERROR: Transformers.js bundle missing.' >&2; exit 1; }

if [ ! -s "$ORT/dist/ort-wasm-simd-threaded.jsep.mjs" ] || [ ! -s "$ORT/dist/ort-wasm-simd-threaded.jsep.wasm" ]; then
  echo '  ↓ ONNX Runtime Web 1.26.0-dev.20260416-b7804b056c'
  rm -rf "$ORT" "$ROOT/translator/vendor/package"
  fetch_pkg 'https://registry.npmjs.org/onnxruntime-web/-/onnxruntime-web-1.26.0-dev.20260416-b7804b056c.tgz' "$ORT_TGZ" 'MD6Ss4GSpQBo6zqoJzyT9LRbKYs7x/JVN23FT24EcEvlqF4VuzPOeH6X38orZPKHQDbprn7K+SBpu0/mj2CQiw=='
  tar -xzf "$ORT_TGZ" -C "$ROOT/translator/vendor"
  mv "$ROOT/translator/vendor/package" "$ORT"
fi
[ -s "$ORT/dist/ort-wasm-simd-threaded.jsep.mjs" ] || { echo 'ERROR: ORT JSEP module factory missing.' >&2; exit 1; }
[ -s "$ORT/dist/ort-wasm-simd-threaded.jsep.wasm" ] || { echo 'ERROR: ORT JSEP WASM binary missing.' >&2; exit 1; }
echo '  ✓ pinned Transformers.js + ONNX Runtime Web assets verified'

M2M_LOCAL_ROOT="$ROOT/models/m2m100-local"
M2M_DIR="$M2M_LOCAL_ROOT/$M2M_MODEL"
M2M_BASE="https://huggingface.co/$M2M_MODEL/resolve/$M2M_REVISION"
mkdir -p "$M2M_DIR/onnx"

download_model_file(){
  local rel="$1" min_bytes="$2" expected_sha="${3:-}" dest="$M2M_DIR/$1" size=0
  if [ -f "$dest" ]; then
    size="$(stat -c '%s' "$dest" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$min_bytes" ]; then
      if [ -z "$expected_sha" ] || printf '%s  %s\n' "$expected_sha" "$dest" | sha256sum -c - >/dev/null 2>&1; then
        echo "  ✓ cached $rel"
        return 0
      fi
      echo "  ! checksum mismatch; refreshing $rel"
    fi
  fi
  mkdir -p "$(dirname "$dest")"
  rm -f "$dest.part"
  echo "  ↓ $rel"
  curl -fL --retry 10 --retry-delay 3 --retry-all-errors --connect-timeout 30 \
    "$M2M_BASE/$rel?download=true" -o "$dest.part"
  size="$(stat -c '%s' "$dest.part" 2>/dev/null || echo 0)"
  [ "$size" -ge "$min_bytes" ] || { echo "ERROR: incomplete model file $rel ($size bytes)" >&2; rm -f "$dest.part"; exit 1; }
  if [ -n "$expected_sha" ]; then
    printf '%s  %s\n' "$expected_sha" "$dest.part" | sha256sum -c - >/dev/null || {
      echo "ERROR: SHA-256 mismatch for $rel" >&2; rm -f "$dest.part"; exit 1;
    }
  fi
  mv -f "$dest.part" "$dest"
}

for f in config.json generation_config.json quantize_config.json special_tokens_map.json tokenizer_config.json; do
  download_model_file "$f" 100
done
download_model_file sentencepiece.bpe.model 2000000 d8f7c76ed2a5e0822be39f0a4f95a55eb19c78f4593ce609e2edbc2aea4d380a
download_model_file tokenizer.json 7000000
download_model_file vocab.json 3000000
download_model_file onnx/encoder_model_quantized.onnx 280000000 13a94e354a9140764eb81102d77d3ec6952d796e6f113c651eeb3c3443da0386
download_model_file onnx/decoder_model_merged_quantized.onnx 330000000 007654bcabb6cea6fd3bde34ce933137b431330b3755781145d7b6906270b45a

echo '  ✓ pinned M2M100 model assets are local and integrity-checked'
deno --version | head -n 1 | sed 's/^/  ✓ /'
