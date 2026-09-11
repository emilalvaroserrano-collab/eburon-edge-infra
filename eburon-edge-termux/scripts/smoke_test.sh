#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"; LOG="$ROOT/logs/smoke.log"; exec > >(tee "$LOG") 2>&1; G="http://127.0.0.1:8850"
EXPECTED_VERSION="$(python -c 'import json,os;print(json.load(open(os.path.expanduser("~/.eburon-edge/config/release.json")))["eburon"])')"
pass(){ printf '  ✓ %s\n' "$1"; }
echo '[smoke] gateway core health';curl -fsS "$G/health"|grep -Eq '"offline_ready"[[:space:]]*:[[:space:]]*true';pass 'gateway core health'
echo '[smoke] release metadata';curl -fsS "$G/v1/system/version"|grep -Fq "$EXPECTED_VERSION";pass "$EXPECTED_VERSION release metadata"
echo '[smoke] translation-only engine';T="$(curl -fsS -H 'content-type: application/json' -d '{"text":"Good morning.","source_language":"en","target_language":"nl"}' "$G/v1/translate")";printf '%s' "$T"|grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+';printf '%s' "$T"|grep -q '"engine":"m2m100"';pass 'M2M100 EN→NL'
echo '[smoke] Supertonic synthesis';curl -fsS -H 'content-type: application/json' -d '{"provider":"supertonic","voice":"M1","language":"en","text":"Eburon voice verification."}' "$G/v1/tts/preview" -o "$ROOT/logs/smoke.wav";[ "$(wc -c < "$ROOT/logs/smoke.wav")" -gt 1000 ];head -c 4 "$ROOT/logs/smoke.wav"|grep -q RIFF;pass 'Supertonic WAV'
echo '[smoke] browser WebM/Opus → Whisper';ffmpeg -loglevel error -y -i "$ROOT/logs/smoke.wav" -c:a libopus -b:a 32k "$ROOT/logs/smoke.webm";S="$(curl -fsS -F "file=@$ROOT/logs/smoke.webm;type=audio/webm" "$G/v1/audio/transcriptions")";printf '%s' "$S"|grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+';pass 'Whisper WebM/Opus transcription'
echo '[smoke] WebSocket end-to-end turn';"$ROOT/venv-gateway/bin/python" - "$ROOT/logs/smoke.webm" <<'PY'
import asyncio,json,pathlib,sys,websockets
audio=pathlib.Path(sys.argv[1]).read_bytes()
async def main():
 g={'t':0,'x':0,'a':0,'c':0}
 async with websockets.connect('ws://127.0.0.1:8850/ws/live',max_size=16*1024*1024) as ws:
  assert json.loads(await asyncio.wait_for(ws.recv(),10)).get('type')=='ready'
  await ws.send(json.dumps({'type':'configure','staff_language':'nl','guest_language':'en','voice':'M1','tts_provider':'supertonic','speaker':True,'audio_mime':'audio/webm'}));await ws.send(audio);await ws.send(json.dumps({'type':'commit','tts':True}))
  while True:
   m=await asyncio.wait_for(ws.recv(),240)
   if isinstance(m,bytes): assert len(m)>1000 and m[:4]==b'RIFF';g['a']=1;continue
   e=json.loads(m);typ=e.get('type')
   if typ=='transcript_final':g['t']=bool(e.get('text'))
   elif typ=='translation_final':g['x']=bool(e.get('text'))
   elif typ=='error':raise RuntimeError(e)
   elif typ=='turn_complete':assert e.get('ok') is True;g['c']=1;break
 assert all(g.values()),g
asyncio.run(main())
PY
pass 'WebSocket STT → translate → TTS'
echo '[smoke] frontend assets';curl -fsS "$G/translate.html"|grep -q '/ws/live';curl -fsS "$G/settings.html"|grep -q '/v1/tts/preview';curl -fsS "$G/service-worker.js"|grep -q "mode==='navigate'";pass 'frontend assets';echo '[smoke] PASS — STT + translation + Supertonic + WebSocket + frontend'
