#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
export EBURON_ROOT="$ROOT"
source "$ROOT/config/eburon.env"
mkdir -p "$ROOT/logs" "$ROOT/run"
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock || true

ok(){ curl -fsS --connect-timeout 1 --max-time 3 "$1" >/dev/null 2>&1; }
start_proc(){
  local name="$1" cmd="$2"
  echo "Starting $name…"
  : > "$ROOT/logs/$name.log"
  nohup bash -lc "$cmd" >>"$ROOT/logs/$name.log" 2>&1 &
  echo $! > "$ROOT/run/$name.pid"
}
wait_ready(){
  local name="$1" url="$2" max="$3" pid
  pid="$(cat "$ROOT/run/$name.pid" 2>/dev/null || true)"
  for _ in $(seq 1 "$max"); do
    if ok "$url"; then echo "  ✓ $name ready"; return 0; fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  echo "ERROR: $name failed to become ready."
  tail -n 80 "$ROOT/logs/$name.log" 2>/dev/null || true
  return 1
}

if ! ok "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/health"; then
  start_proc translator "cd '$ROOT/translator'; EBURON_TRANSLATOR_PORT='$EBURON_TRANSLATOR_PORT' EBURON_TRANSLATOR_CACHE='$ROOT/models/m2m100-cache' EBURON_OFFLINE=1 M2M_MODEL='$M2M_MODEL' M2M_REVISION='$M2M_REVISION' exec node server.mjs"
  wait_ready translator "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/health" 40
fi
if ! curl -fsS -X POST --max-time 240 "http://127.0.0.1:$EBURON_TRANSLATOR_PORT/warmup" >/dev/null; then
  echo 'ERROR: translator offline warm-up failed.'
  tail -n 100 "$ROOT/logs/translator.log" 2>/dev/null || true
  exit 1
fi
echo '  ✓ translator model resident'

if ! ok "http://127.0.0.1:$EBURON_STT_PORT/"; then
  start_proc stt "exec '$ROOT/bin/whisper-server' --host 127.0.0.1 --port '$EBURON_STT_PORT' -m '$ROOT/models/$WHISPER_MODEL_NAME' -l auto -t '$WHISPER_THREADS' --convert -ng -sns"
  wait_ready stt "http://127.0.0.1:$EBURON_STT_PORT/" 90
fi

if ! ok "http://127.0.0.1:$EBURON_TTS_PORT/v1/health"; then
  start_proc supertonic "source '$ROOT/venv-tts/bin/activate'; cd '$ROOT'; SUPERTONIC_MODEL_DIR='$ROOT/models/supertonic-3' exec uvicorn gateway.tts_server:app --host 127.0.0.1 --port '$EBURON_TTS_PORT' --log-level warning"
  wait_ready supertonic "http://127.0.0.1:$EBURON_TTS_PORT/v1/health" 45
fi

# Piper sidecar exposes catalogue metadata even when synthesis runtime is absent.
if ! ok "http://127.0.0.1:$EBURON_PIPER_PORT/v1/voices"; then
  start_proc piper "source '$ROOT/venv-gateway/bin/activate'; cd '$ROOT'; exec uvicorn gateway.piper_server:app --host 127.0.0.1 --port '$EBURON_PIPER_PORT' --log-level warning"
  wait_ready piper "http://127.0.0.1:$EBURON_PIPER_PORT/v1/voices" 20 || true
fi

if ! ok "http://127.0.0.1:$EBURON_GATEWAY_PORT/health"; then
  start_proc gateway "source '$ROOT/venv-gateway/bin/activate'; cd '$ROOT'; exec uvicorn gateway.server:app --host 127.0.0.1 --port '$EBURON_GATEWAY_PORT' --log-level warning"
  wait_ready gateway "http://127.0.0.1:$EBURON_GATEWAY_PORT/health" 45
fi

HEALTH="$(curl -fsS --max-time 5 "http://127.0.0.1:$EBURON_GATEWAY_PORT/health")"
printf '%s' "$HEALTH" | grep -Eq '"offline_ready"[[:space:]]*:[[:space:]]*true' || {
  echo 'ERROR: required offline core is not ready.'
  printf '%s\n' "$HEALTH"
  exit 1
}
curl -fsS --max-time 5 "http://127.0.0.1:$EBURON_GATEWAY_PORT/v1/system/version" | grep -q '"v0.2.0"' || {
  echo 'ERROR: gateway release identity mismatch.'
  exit 1
}
echo "Eburon Edge v0.2.0 READY at http://127.0.0.1:$EBURON_GATEWAY_PORT"
