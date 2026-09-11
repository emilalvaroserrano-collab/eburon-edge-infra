from __future__ import annotations
import json, os, pathlib
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route
ROOT=pathlib.Path(os.getenv("EBURON_ROOT",pathlib.Path.home()/".eburon-edge"))
CAT=ROOT/"models"/"piper"/"voices.json"

def catalogue():
    try: return json.loads(CAT.read_text()) if CAT.exists() else {}
    except Exception: return {}

async def health(request:Request):
    data=catalogue()
    return JSONResponse({"status":"unavailable","catalogue_available":bool(data),"runtime_available":False,"installed_voice_count":0},status_code=503)

async def voices(request:Request):
    data=catalogue(); items=[]
    for key,val in data.items():
        if not isinstance(val,dict): continue
        lang=val.get("language",{}) if isinstance(val.get("language"),dict) else {}
        items.append({"id":key,"name":key,"language":lang.get("code") or "","quality":val.get("quality") or "","installed":False})
    return JSONResponse({"provider":"piper","catalogue_available":bool(data),"runtime_available":False,"voices":items})

async def tts(request:Request):
    return JSONResponse({"error":"Piper synthesis is disabled until an isolated Android runtime is verified"},status_code=503)

app=Starlette(routes=[Route("/v1/health",health),Route("/v1/voices",voices),Route("/v1/tts",tts,methods=["POST"])])
