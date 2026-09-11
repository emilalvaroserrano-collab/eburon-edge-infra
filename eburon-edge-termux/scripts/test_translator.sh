#!/usr/bin/env bash
set -euo pipefail
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
source "$ROOT/config/eburon.env"
PORT="${EBURON_TRANSLATOR_PORT:-8851}"
BASE="http://127.0.0.1:$PORT"
LOG="$ROOT/logs/translator-runtime-test.log"
WARM="$ROOT/logs/translator-runtime-warmup.json"
mkdir -p "$ROOT/logs" "$ROOT/run"
: >"$LOG"; : >"$WARM"

pid=''
cleanup(){
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

EBURON_ROOT="$ROOT" "$ROOT/scripts/run_translator.sh" >>"$LOG" 2>&1 &
pid=$!
for _ in $(seq 1 120); do
  if curl -fsS --max-time 2 "$BASE/health" >/dev/null 2>&1; then break; fi
  kill -0 "$pid" 2>/dev/null || { echo 'ERROR: translator exited before health became ready' >&2; tail -n 200 "$LOG"; exit 1; }
  sleep .5
done

H="$(curl -fsS --max-time 3 "$BASE/health")" || { tail -n 200 "$LOG"; exit 1; }
printf '%s' "$H" | grep -q '"runtime":"deno-transformersjs-web-wasm"' || { echo "ERROR: unexpected translator runtime: $H" >&2; exit 1; }
echo '  ✓ Deno translator HTTP process ready'

curl -fsS --max-time 10 "$BASE/models/$M2M_MODEL/config.json" >/dev/null || { echo 'ERROR: local M2M100 model route failed' >&2; exit 1; }
curl -fsS --max-time 10 "$BASE/ort/ort-wasm-simd-threaded.jsep.mjs" >/dev/null || { echo 'ERROR: local ORT mjs route failed' >&2; exit 1; }
curl -fsS --max-time 10 "$BASE/ort/ort-wasm-simd-threaded.jsep.wasm" -o /dev/null || { echo 'ERROR: local ORT wasm route failed' >&2; exit 1; }
echo '  ✓ local model + ORT assets reachable'

code="$(curl -sS -X POST --max-time 1200 -o "$WARM" -w '%{http_code}' "$BASE/warmup" || true)"
if [ "$code" != '200' ]; then
  echo "ERROR: M2M100 warm-up failed (HTTP ${code:-curl-error})" >&2
  cat "$WARM" 2>/dev/null || true; echo
  tail -n 240 "$LOG" 2>/dev/null || true
  exit 1
fi
cat "$WARM"
echo

OUT="$(curl -fsS --max-time 300 -H 'content-type: application/json' \
  -d '{"text":"Good morning.","source_language":"en","target_language":"nl"}' \
  "$BASE/v1/translate")"
printf '%s' "$OUT" | grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+' || { echo "ERROR: empty translation: $OUT" >&2; exit 1; }
printf '%s' "$OUT" | grep -q '"engine":"m2m100"' || { echo "ERROR: wrong translator engine: $OUT" >&2; exit 1; }
echo "  ✓ Deno M2M100 EN→NL inference verified: $OUT"
