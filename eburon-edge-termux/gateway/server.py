from __future__ import annotations
import asyncio, json, os, pathlib, time
from contextlib import asynccontextmanager
import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, Response
from starlette.routing import Route, WebSocketRoute
from starlette.websockets import WebSocket, WebSocketDisconnect

ROOT=pathlib.Path(os.getenv('EBURON_ROOT',pathlib.Path(__file__).resolve().parents[1]))
PUBLIC=ROOT/'public'
RELEASE=ROOT/'config'/'release.json'
GP=int(os.getenv('EBURON_GATEWAY_PORT','8850')); TP=int(os.getenv('EBURON_TRANSLATOR_PORT','8851')); SP=int(os.getenv('EBURON_STT_PORT','8852')); STP=int(os.getenv('EBURON_TTS_PORT','8853')); PP=int(os.getenv('EBURON_PIPER_PORT','8854'))
TU=f'http://127.0.0.1:{TP}'; SU=f'http://127.0.0.1:{SP}'; STU=f'http://127.0.0.1:{STP}'; PU=f'http://127.0.0.1:{PP}'
client:httpx.AsyncClient|None=None
LANGUAGES=[('en','English'),('nl','Dutch / Flemish'),('fr','French'),('de','German'),('es','Spanish'),('it','Italian'),('pt','Portuguese'),('pl','Polish'),('ar','Arabic'),('hi','Hindi'),('id','Indonesian'),('ja','Japanese'),('ko','Korean'),('ru','Russian'),('uk','Ukrainian'),('tr','Turkish'),('vi','Vietnamese'),('sv','Swedish'),('da','Danish'),('fi','Finnish'),('cs','Czech'),('bg','Bulgarian'),('el','Greek'),('et','Estonian'),('hr','Croatian'),('hu','Hungarian'),('lt','Lithuanian'),('lv','Latvian'),('ro','Romanian'),('sk','Slovak'),('sl','Slovenian')]
LANG_CODES={c for c,_ in LANGUAGES}
VOICES=[{'id':x,'name':x,'gender':'female' if x.startswith('F') else 'male'} for x in ['F1','F2','F3','F4','F5','M1','M2','M3','M4','M5']]

def lang(v:str)->str:
    x=(v or 'auto').strip().lower().replace('_','-').split('-')[0]
    aliases={'flemish':'nl','dutch':'nl','english':'en','french':'fr','german':'de','spanish':'es','filipino':'tl','tagalog':'tl'}
    return aliases.get(x,x)

@asynccontextmanager
async def lifespan(app):
    global client
    client=httpx.AsyncClient(timeout=httpx.Timeout(180,connect=5))
    try: yield
    finally: await client.aclose()

async def probe(url:str)->bool:
    try: return (await client.get(url,timeout=2)).status_code<500
    except Exception: return False

async def health(request:Request):
    tr,st,tts=await asyncio.gather(probe(TU+'/health'),probe(SU+'/'),probe(STU+'/v1/health'))
    return JSONResponse({'status':'ready' if tr and st and tts else 'starting','offline_ready':tr and st and tts,'components':{'translator':tr,'stt':st,'tts':{'supertonic':tts,'piper':await probe(PU+'/v1/health')}},'ports':{'gateway':GP,'translator':TP,'stt':SP,'supertonic':STP,'piper':PP}})

async def version(request:Request):
    try: return JSONResponse(json.loads(RELEASE.read_text()))
    except Exception as e: return JSONResponse({'error':str(e)},status_code=500)

async def languages(request:Request): return JSONResponse({'languages':[{'code':c,'name':n} for c,n in LANGUAGES]})

async def transcribe_bytes(audio:bytes,mime='audio/webm'):
    t=time.perf_counter(); r=await client.post(SU+'/inference',files={'file':('utterance.webm',audio,mime)},data={'language':'auto','response_format':'verbose_json','temperature':'0.0'})
    if r.status_code>=400: raise RuntimeError(f'whisper {r.status_code}: {r.text[:300]}')
    j=r.json(); return str(j.get('text') or '').strip(),lang(str(j.get('detected_language') or j.get('language') or 'auto')),(time.perf_counter()-t)*1000

async def transcribe_api(request:Request):
    form=await request.form(); up=form.get('file')
    if up is None: return JSONResponse({'error':'file is required'},status_code=400)
    text,det,ms=await transcribe_bytes(await up.read(),getattr(up,'content_type','audio/webm') or 'audio/webm')
    return JSONResponse({'text':text,'language':det,'latency_ms':round(ms)})

async def translate(text,src,tgt):
    t=time.perf_counter(); r=await client.post(TU+'/v1/translate',json={'text':text,'source_language':lang(src),'target_language':lang(tgt)})
    if r.status_code>=400: raise RuntimeError(f'translator {r.status_code}: {r.text[:300]}')
    j=r.json(); out=str(j.get('text') or '').strip()
    if not out: raise RuntimeError('empty translation')
    return out,(time.perf_counter()-t)*1000

async def translate_api(request:Request):
    b=await request.json(); text=str(b.get('text') or '').strip()
    if not text: return JSONResponse({'error':'text is required'},status_code=400)
    try:
        out,ms=await translate(text,b.get('source_language','en'),b.get('target_language','nl')); return JSONResponse({'text':out,'source_language':lang(b.get('source_language','en')),'target_language':lang(b.get('target_language','nl')),'engine':'m2m100','latency_ms':round(ms)})
    except Exception as e: return JSONResponse({'error':str(e)},status_code=500)

async def synth(text,provider,voice,target):
    p=(provider or 'supertonic').lower(); base=STU if p=='supertonic' else PU
    if p!='supertonic' and not await probe(base+'/v1/health'): p='supertonic'; base=STU; voice='M1'
    t=time.perf_counter(); r=await client.post(base+'/v1/tts',json={'text':text,'voice':voice or 'M1','lang':lang(target),'steps':int(os.getenv('TTS_STEPS','4')),'speed':float(os.getenv('TTS_SPEED','1.05'))})
    if r.status_code>=400: raise RuntimeError(f'{p} TTS {r.status_code}: {r.text[:300]}')
    return r.content,(time.perf_counter()-t)*1000,p

async def providers(request:Request):
    s,p=await asyncio.gather(probe(STU+'/v1/health'),probe(PU+'/v1/health'))
    return JSONResponse({'providers':[{'id':'supertonic','name':'Supertonic 3','available':s,'recommended':True},{'id':'piper','name':'Piper','available':p,'recommended':False},{'id':'kokoro','name':'Kokoro','available':False,'recommended':False}]})

async def catalog(request:Request):
    p=request.query_params.get('provider','supertonic').lower()
    if p=='supertonic': return JSONResponse({'provider':'supertonic','available':await probe(STU+'/v1/health'),'languages':[{'code':c,'name':n} for c,n in LANGUAGES],'voices':VOICES})
    if p=='piper':
        try:
            r=await client.get(PU+'/v1/voices',timeout=10); return JSONResponse(r.json(),status_code=r.status_code)
        except Exception: pass
    return JSONResponse({'provider':p,'available':False,'languages':[],'voices':[]})

async def preview(request:Request):
    b=await request.json()
    try:
        wav,ms,p=await synth(str(b.get('text') or 'Hello. This is your selected Eburon voice.'),str(b.get('provider') or 'supertonic'),str(b.get('voice') or 'M1'),str(b.get('language') or 'en')); return Response(wav,media_type='audio/wav',headers={'X-Eburon-TTS-Provider':p,'X-Eburon-TTS-Latency-Ms':str(round(ms))})
    except Exception as e: return JSONResponse({'error':str(e)},status_code=500)

def direction(detected,cfg):
    staff,guest=lang(cfg.get('staff_language','nl')),lang(cfg.get('guest_language','en'))
    if detected==staff:return staff,guest
    if detected==guest:return guest,staff
    return (detected if detected!='auto' else guest),staff

async def live(ws:WebSocket):
    await ws.accept(); parts=[]; cfg={'staff_language':'nl','guest_language':'en','voice':'M1','tts_provider':'supertonic','speaker':True,'audio_mime':'audio/webm'}; await ws.send_json({'type':'ready'})
    try:
        while True:
            m=await ws.receive()
            if m.get('bytes') is not None: parts.append(m['bytes']); continue
            raw=m.get('text')
            if raw is None: continue
            try: ev=json.loads(raw)
            except Exception: await ws.send_json({'type':'error','stage':'protocol','message':'invalid json'}); continue
            typ=ev.get('type')
            if typ=='configure': cfg.update({k:v for k,v in ev.items() if k!='type'}); await ws.send_json({'type':'configured'}); continue
            if typ=='clear': parts.clear(); continue
            if typ!='commit': continue
            if not parts: await ws.send_json({'type':'error','stage':'stt','message':'no audio'}); await ws.send_json({'type':'turn_complete','ok':False}); continue
            audio=b''.join(parts); parts.clear(); started=time.perf_counter()
            try:
                await ws.send_json({'type':'stage','stage':'stt'}); text,det,stt_ms=await transcribe_bytes(audio,cfg.get('audio_mime','audio/webm'))
                if not text: await ws.send_json({'type':'turn_complete','ok':True,'empty':True}); continue
                src,tgt=direction(det,cfg); await ws.send_json({'type':'transcript_final','text':text,'language':det,'source_language':src,'target_language':tgt,'latency_ms':round(stt_ms)})
                await ws.send_json({'type':'stage','stage':'translate'}); out,tr_ms=await translate(text,src,tgt); await ws.send_json({'type':'translation_final','text':out,'source_language':src,'target_language':tgt,'latency_ms':round(tr_ms)})
                tts_ms=0; used=cfg.get('tts_provider','supertonic')
                if cfg.get('speaker',True) and ev.get('tts',True):
                    await ws.send_json({'type':'stage','stage':'tts'}); wav,tts_ms,used=await synth(out,used,cfg.get('voice','M1'),tgt); await ws.send_json({'type':'tts_begin','mime':'audio/wav','bytes':len(wav),'provider':used,'latency_ms':round(tts_ms)}); await ws.send_bytes(wav)
                await ws.send_json({'type':'turn_complete','ok':True,'stt_ms':round(stt_ms),'translate_ms':round(tr_ms),'tts_ms':round(tts_ms),'total_ms':round((time.perf_counter()-started)*1000)})
            except Exception as e: await ws.send_json({'type':'error','stage':'pipeline','message':str(e)[:500]}); await ws.send_json({'type':'turn_complete','ok':False})
    except WebSocketDisconnect: return

async def static(request:Request):
    p=request.path_params.get('path') or 'index.html'; target=(PUBLIC/p).resolve()
    if not str(target).startswith(str(PUBLIC.resolve())) or not target.is_file(): return Response('Not found',status_code=404)
    return FileResponse(target)

app=Starlette(lifespan=lifespan,routes=[Route('/health',health),Route('/v1/system/version',version),Route('/v1/languages',languages),Route('/v1/audio/transcriptions',transcribe_api,methods=['POST']),Route('/v1/translate',translate_api,methods=['POST']),Route('/v1/tts/providers',providers),Route('/v1/tts/catalog',catalog),Route('/v1/tts/preview',preview,methods=['POST']),WebSocketRoute('/ws/live',live),Route('/{path:path}',static)])
