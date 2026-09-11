#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
LOG="$ROOT/logs/smoke.log"
exec > >(tee "$LOG") 2>&1
G=http://127.0.0.1:8850
T=http://127.0.0.1:8851
EXPECTED_VERSION="$(EBURON_ROOT="$ROOT" python -c 'import json,os;print(json.load(open(os.path.join(os.environ["EBURON_ROOT"],"config","release.json")))["eburon"])')"
pass(){ echo "  ✓ $1"; }

TH="$(curl -fsS "$T/health")"
printf '%s' "$TH"|grep -Eq '"model_loaded"[[:space:]]*:[[:space:]]*true'
printf '%s' "$TH"|grep -q '"runtime":"deno-transformersjs-web-wasm"'
pass 'Deno M2M100 model resident'

curl -fsS "$G/health"|grep -Eq '"offline_ready"[[:space:]]*:[[:space:]]*true'
pass 'gateway core health'
curl -fsS "$G/v1/system/version"|grep -Fq "$EXPECTED_VERSION"
pass "$EXPECTED_VERSION release metadata"

TJSON="$(curl -fsS -H 'content-type: application/json' -d '{"text":"Good morning.","source_language":"en","target_language":"nl"}' "$G/v1/translate")"
printf '%s' "$TJSON"|grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+'
printf '%s' "$TJSON"|grep -q '"engine":"m2m100"'
pass 'M2M100 EN→NL'

curl -fsS -H 'content-type: application/json' \
  -d '{"provider":"supertonic","voice":"M1","language":"en","text":"Eburon voice verification."}' \
  "$G/v1/tts/preview" -o "$ROOT/logs/smoke.wav"
[ "$(wc -c<"$ROOT/logs/smoke.wav")" -gt 1000 ]
head -c4 "$ROOT/logs/smoke.wav"|grep -q RIFF
pass 'Supertonic WAV'

ffmpeg -loglevel error -y -i "$ROOT/logs/smoke.wav" -c:a libopus -b:a 32k "$ROOT/logs/smoke.webm"
SJSON="$(curl -fsS -F "file=@$ROOT/logs/smoke.webm;type=audio/webm" "$G/v1/audio/transcriptions")"
printf '%s' "$SJSON"|grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+'
pass 'Whisper browser WebM'

"$ROOT/venv-gateway/bin/python" - "$ROOT/logs/smoke.webm" <<'PY'
import asyncio,json,pathlib,sys,websockets
A=pathlib.Path(sys.argv[1]).read_bytes()
async def m():
 g={'t':0,'x':0,'a':0,'c':0}
 async with websockets.connect('ws://127.0.0.1:8850/ws/live',max_size=16*1024*1024) as w:
  assert json.loads(await asyncio.wait_for(w.recv(),10))['type']=='ready'
  await w.send(json.dumps({'type':'configure','staff_language':'nl','guest_language':'en','voice':'M1','tts_provider':'supertonic','speaker':True,'audio_mime':'audio/webm'}))
  await w.send(A)
  await w.send(json.dumps({'type':'commit','tts':True}))
  while True:
   z=await asyncio.wait_for(w.recv(),300)
   if isinstance(z,bytes):
    assert z[:4]==b'RIFF' and len(z)>1000
    g['a']=1
    continue
   e=json.loads(z); q=e.get('type')
   if q=='transcript_final': g['t']=bool(e.get('text'))
   elif q=='translation_final': g['x']=bool(e.get('text'))
   elif q=='error': raise RuntimeError(e)
   elif q=='turn_complete':
    assert e.get('ok')
    g['c']=1
    break
 assert all(g.values()),g
asyncio.run(m())
PY
pass 'WebSocket STT → translate → TTS'

curl -fsS "$G/translate.html"|grep -q '/ws/live'
curl -fsS "$G/translate.html"|grep -q 'Tap microphone to start'
curl -fsS "$G/settings.html"|grep -q '/v1/tts/preview'
curl -fsS "$G/service-worker.js"|grep -q "mode==='navigate'"
pass 'frontend assets + explicit audio arm'
echo '[smoke] PASS — Deno translator + mic frontend + STT + translation + Supertonic + WebSocket verified'
