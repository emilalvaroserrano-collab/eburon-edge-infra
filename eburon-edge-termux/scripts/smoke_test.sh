#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
LOG="$ROOT/logs/smoke.log"
exec > >(tee "$LOG") 2>&1
G="http://127.0.0.1:8850"

pass(){ printf '  ✓ %s\n' "$1"; }

echo '[smoke] gateway core health'
curl -fsS "$G/health" | grep -Eq '"offline_ready"[[:space:]]*:[[:space:]]*true'
pass 'gateway core health'

echo '[smoke] immutable release metadata'
curl -fsS "$G/v1/system/version" | grep -q '"v0.2.0"'
pass 'release metadata'

echo '[smoke] translation-only engine'
TJSON="$(curl -fsS -H 'content-type: application/json' -d '{"text":"Good morning.","source_language":"en","target_language":"nl"}' "$G/v1/translate")"
printf '%s' "$TJSON" | grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+'
printf '%s' "$TJSON" | grep -q '"engine":"m2m100"'
pass 'M2M100 EN→NL'

echo '[smoke] Supertonic synthesis'
curl -fsS -H 'content-type: application/json' \
  -d '{"provider":"supertonic","voice":"M1","language":"en","text":"Eburon voice verification."}' \
  "$G/v1/tts/preview" -o "$ROOT/logs/smoke.wav"
[ "$(wc -c < "$ROOT/logs/smoke.wav")" -gt 1000 ]
head -c 4 "$ROOT/logs/smoke.wav" | grep -q 'RIFF'
pass 'Supertonic WAV'

echo '[smoke] browser codec WebM/Opus → Whisper'
ffmpeg -loglevel error -y -i "$ROOT/logs/smoke.wav" -c:a libopus -b:a 32k "$ROOT/logs/smoke.webm"
SJSON="$(curl -fsS -F "file=@$ROOT/logs/smoke.webm;type=audio/webm" "$G/v1/audio/transcriptions")"
printf '%s' "$SJSON" | grep -Eq '"text"[[:space:]]*:[[:space:]]*"[^\"]+'
pass 'Whisper WebM/Opus transcription'

echo '[smoke] WebSocket end-to-end turn'
"$ROOT/venv-gateway/bin/python" - "$ROOT/logs/smoke.webm" <<'PY'
import asyncio, json, pathlib, sys
import websockets
AUDIO=pathlib.Path(sys.argv[1]).read_bytes()
async def main():
    got={'transcript':False,'translation':False,'audio':False,'complete':False}
    async with websockets.connect('ws://127.0.0.1:8850/ws/live',max_size=16*1024*1024) as ws:
        first=json.loads(await asyncio.wait_for(ws.recv(),10))
        assert first.get('type')=='ready', first
        await ws.send(json.dumps({'type':'configure','staff_language':'nl','guest_language':'en','voice':'M1','tts_provider':'supertonic','speaker':True,'audio_mime':'audio/webm'}))
        await ws.send(AUDIO)
        await ws.send(json.dumps({'type':'commit','tts':True}))
        while True:
            msg=await asyncio.wait_for(ws.recv(),240)
            if isinstance(msg,bytes):
                assert len(msg)>1000 and msg[:4]==b'RIFF'
                got['audio']=True
                continue
            event=json.loads(msg)
            typ=event.get('type')
            if typ=='transcript_final': got['transcript']=bool(event.get('text'))
            elif typ=='translation_final': got['translation']=bool(event.get('text'))
            elif typ=='error': raise RuntimeError(event)
            elif typ=='turn_complete':
                assert event.get('ok') is True, event
                got['complete']=True
                break
    assert all(got.values()), got
asyncio.run(main())
PY
pass 'WebSocket STT → translate → TTS'

echo '[smoke] frontend and service worker'
curl -fsS "$G/translate.html" | grep -q '/ws/live'
curl -fsS "$G/settings.html" | grep -q '/v1/tts/preview'
curl -fsS "$G/service-worker.js" | grep -q "mode==='navigate'"
pass 'frontend assets'

echo '[smoke] PASS — STT + translation + Supertonic + WebSocket + frontend'
