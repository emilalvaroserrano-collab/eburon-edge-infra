import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { pathToFileURL } from "node:url";
import { env, pipeline } from "./vendor/transformers/dist/transformers.js";

const PORT=Number(process.env.EBURON_TRANSLATOR_PORT||8851);
const MODEL=process.env.M2M_MODEL||process.env.EBURON_TRANSLATOR_MODEL||"huggingworld/m2m100_418M";
const REVISION=process.env.M2M_REVISION||"48f06c0fec544323fcf1546e312a617d962d3653";
const CACHE=process.env.EBURON_TRANSLATOR_CACHE||path.join(os.homedir(),".eburon-edge","models","m2m100-cache");
const ROOT=path.dirname(new URL(import.meta.url).pathname);
fs.mkdirSync(CACHE,{recursive:true});
env.cacheDir=CACHE;
env.allowLocalModels=true;
env.allowRemoteModels=process.env.EBURON_OFFLINE!=="1";
try { env.backends.onnx.wasm.wasmPaths=pathToFileURL(path.join(ROOT,"vendor","onnxruntime-web","dist")+path.sep).href; } catch {}

let translator=null,initPromise=null,initError=null;
async function init(){
  if(translator) return translator;
  if(initPromise) return initPromise;
  initPromise=(async()=>{try{translator=await pipeline("translation",MODEL,{dtype:"q8",device:"wasm",revision:REVISION});return translator;}catch(e){initError=String(e?.stack||e);initPromise=null;throw e;}})();
  return initPromise;
}
function json(res,status,obj){const b=Buffer.from(JSON.stringify(obj));res.writeHead(status,{"content-type":"application/json","content-length":b.length,"cache-control":"no-store"});res.end(b);}
async function body(req){const chunks=[];for await(const c of req)chunks.push(c);return JSON.parse(Buffer.concat(chunks).toString("utf8")||"{}");}
const server=http.createServer(async(req,res)=>{try{
  if(req.method==="GET"&&req.url==="/health"){json(res,200,{status:"ready",engine:"m2m100",model:MODEL,revision:REVISION,process_ready:true,model_loaded:translator!==null,init_error:initError,thinking:false});return;}
  if(req.method==="POST"&&req.url==="/warmup"){const t=await init();const out=await t("Good morning.",{src_lang:"en",tgt_lang:"nl",max_new_tokens:32,num_beams:1,do_sample:false});json(res,200,{status:"ready",model_loaded:true,sample:out?.[0]?.translation_text||""});return;}
  if(req.method==="POST"&&req.url==="/v1/translate"){
    const b=await body(req),text=String(b.text||"").trim(),src=String(b.source_language||"en").split(/[-_]/)[0].toLowerCase(),tgt=String(b.target_language||"nl").split(/[-_]/)[0].toLowerCase();
    if(!text){json(res,400,{error:"text is required"});return;} if(src===tgt){json(res,200,{text,source_language:src,target_language:tgt,engine:"m2m100",latency_ms:0});return;}
    const t=await init(),started=performance.now(); const out=await t(text,{src_lang:src,tgt_lang:tgt,max_new_tokens:256,num_beams:1,do_sample:false}); const translated=String(out?.[0]?.translation_text||"").trim();
    if(!translated) throw new Error("translation engine returned empty text"); json(res,200,{text:translated,source_language:src,target_language:tgt,engine:"m2m100",latency_ms:Math.round(performance.now()-started)});return;
  }
  json(res,404,{error:"not found"});
}catch(e){json(res,500,{error:String(e?.message||e)})}});
server.listen(PORT,"127.0.0.1",()=>console.log(`M2M100 translator listening on 127.0.0.1:${PORT}`));
