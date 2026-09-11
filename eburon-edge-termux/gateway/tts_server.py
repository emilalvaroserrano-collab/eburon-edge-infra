from __future__ import annotations
import io, os, threading, wave
import numpy as np
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route
from supertonic import TTS

_tts=None
_init_lock=threading.Lock()
_synth_lock=threading.Lock()
_verified=False
VOICES=["F1","F2","F3","F4","F5","M1","M2","M3","M4","M5"]

def get_tts():
    global _tts
    if _tts is None:
        with _init_lock:
            if _tts is None:
                _tts=TTS(model_dir=os.environ["SUPERTONIC_MODEL_DIR"],auto_download=False)
    return _tts

def wav_bytes(audio,sample_rate:int)->bytes:
    arr=np.clip(np.asarray(audio).squeeze(),-1.0,1.0)
    pcm=(arr*32767.0).astype(np.int16).tobytes()
    buf=io.BytesIO()
    with wave.open(buf,"wb") as wf:
        wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(sample_rate); wf.writeframes(pcm)
    return buf.getvalue()

async def health(request:Request):
    model_dir=os.environ.get("SUPERTONIC_MODEL_DIR","")
    required=["onnx/duration_predictor.onnx","onnx/text_encoder.onnx","onnx/vector_estimator.onnx","onnx/vocoder.onnx","onnx/tts.json","onnx/unicode_indexer.json","voice_styles/M1.json"]
    missing=[p for p in required if not os.path.isfile(os.path.join(model_dir,p))]
    if missing:
        return JSONResponse({"status":"error","runtime":"supertonic-3","assets_ready":False,"missing":missing},status_code=503)
    return JSONResponse({"status":"ready","runtime":"supertonic-3","assets_ready":True,"model_loaded":_tts is not None,"synthesis_verified":_verified,"voices":VOICES})

async def synthesize(request:Request):
    global _verified
    body=await request.json()
    text=str(body.get("text") or body.get("input") or "").strip()
    if not text: return JSONResponse({"error":"text is required"},status_code=400)
    voice=str(body.get("voice") or os.getenv("TTS_VOICE","M1"))
    lang=str(body.get("lang") or body.get("language") or "na").split("-")[0]
    steps=int(body.get("steps") or os.getenv("TTS_STEPS","4"))
    speed=float(body.get("speed") or os.getenv("TTS_SPEED","1.05"))
    try:
        # ONNX sessions are shared by the TTS object. Serialize synthesis, but
        # keep model initialization on a separate lock so the first request
        # cannot deadlock by re-acquiring the same non-reentrant lock.
        with _synth_lock:
            tts=get_tts(); style=tts.get_voice_style(voice_name=voice)
            audio,_=tts.synthesize(text,voice_style=style,total_steps=steps,speed=speed,lang=lang)
            out=wav_bytes(audio,tts.sample_rate); _verified=True
        return Response(out,media_type="audio/wav")
    except Exception as e:
        return JSONResponse({"error":str(e)},status_code=500)

app=Starlette(routes=[Route("/v1/health",health),Route("/v1/tts",synthesize,methods=["POST"]),Route("/v1/audio/speech",synthesize,methods=["POST"])])
