import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { env, pipeline } from "./vendor/transformers/dist/transformers.js";

const PORT = Number(process.env.EBURON_TRANSLATOR_PORT || 8851);
const MODEL = process.env.M2M_MODEL || process.env.EBURON_TRANSLATOR_MODEL || "huggingworld/m2m100_418M";
const REVISION = process.env.M2M_REVISION || "48f06c0fec544323fcf1546e312a617d962d3653";
const HERE = path.dirname(fileURLToPath(import.meta.url));
const LOCAL_ROOT = process.env.M2M_LOCAL_ROOT || path.join(os.homedir(), ".eburon-edge", "models", "m2m100-local");
const ORT_ROOT = path.join(HERE, "vendor", "onnxruntime-web", "dist");

env.allowLocalModels = true;
env.allowRemoteModels = false;
env.localModelPath = `http://127.0.0.1:${PORT}/models/`;
env.useBrowserCache = false;
try {
  env.backends.onnx.wasm.wasmPaths = `http://127.0.0.1:${PORT}/ort/`;
  env.backends.onnx.wasm.numThreads = 1;
} catch {}

let translator = null;
let initPromise = null;
let initError = null;

function safeJoin(root, relative) {
  const target = path.resolve(root, relative);
  const base = path.resolve(root);
  if (target !== base && !target.startsWith(base + path.sep)) return null;
  return target;
}

function contentType(file) {
  if (file.endsWith(".json")) return "application/json";
  if (file.endsWith(".wasm")) return "application/wasm";
  if (file.endsWith(".mjs") || file.endsWith(".js")) return "text/javascript";
  return "application/octet-stream";
}

function serveLocalFile(req, res, root, relative) {
  let decoded;
  try { decoded = decodeURIComponent(relative); } catch { res.writeHead(400); res.end(); return true; }
  const target = safeJoin(root, decoded);
  if (!target) { res.writeHead(403); res.end(); return true; }
  let stat;
  try { stat = fs.statSync(target); } catch { res.writeHead(404); res.end(); return true; }
  if (!stat.isFile()) { res.writeHead(404); res.end(); return true; }
  res.writeHead(200, {
    "content-type": contentType(target),
    "content-length": stat.size,
    "cache-control": "public, max-age=31536000, immutable",
  });
  fs.createReadStream(target).pipe(res);
  return true;
}

async function init() {
  if (translator) return translator;
  if (initPromise) return initPromise;
  initPromise = (async () => {
    try {
      translator = await pipeline("translation", MODEL, {
        dtype: "q8",
        device: "wasm",
        local_files_only: true,
      });
      initError = null;
      return translator;
    } catch (e) {
      initError = String(e?.stack || e);
      initPromise = null;
      throw e;
    }
  })();
  return initPromise;
}

function json(res, status, obj) {
  const b = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": b.length,
    "cache-control": "no-store",
  });
  res.end(b);
}

async function body(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
}

const server = http.createServer(async (req, res) => {
  try {
    const u = new URL(req.url || "/", `http://127.0.0.1:${PORT}`);
    if (req.method === "GET" && u.pathname.startsWith("/models/")) {
      return serveLocalFile(req, res, LOCAL_ROOT, u.pathname.slice("/models/".length));
    }
    if (req.method === "GET" && u.pathname.startsWith("/ort/")) {
      return serveLocalFile(req, res, ORT_ROOT, u.pathname.slice("/ort/".length));
    }
    if (req.method === "GET" && u.pathname === "/health") {
      json(res, 200, {
        status: "ready",
        engine: "m2m100",
        model: MODEL,
        revision: REVISION,
        process_ready: true,
        model_loaded: translator !== null,
        model_root: LOCAL_ROOT,
        init_error: initError,
        thinking: false,
      });
      return;
    }
    if (req.method === "POST" && u.pathname === "/warmup") {
      const t = await init();
      const out = await t("Good morning.", {
        src_lang: "en",
        tgt_lang: "nl",
        max_new_tokens: 32,
        num_beams: 1,
        do_sample: false,
      });
      const sample = String(out?.[0]?.translation_text || "").trim();
      if (!sample) throw new Error("M2M100 warm-up returned empty text");
      json(res, 200, { status: "ready", model_loaded: true, sample });
      return;
    }
    if (req.method === "POST" && u.pathname === "/v1/translate") {
      const b = await body(req);
      const text = String(b.text || "").trim();
      const src = String(b.source_language || b.src_lang || "en").split(/[-_]/)[0].toLowerCase();
      const tgt = String(b.target_language || b.tgt_lang || "nl").split(/[-_]/)[0].toLowerCase();
      if (!text) { json(res, 400, { error: "text is required" }); return; }
      if (src === tgt) {
        json(res, 200, { text, source_language: src, target_language: tgt, engine: "m2m100", latency_ms: 0 });
        return;
      }
      const t = await init();
      const started = performance.now();
      const out = await t(text, {
        src_lang: src,
        tgt_lang: tgt,
        max_new_tokens: 256,
        num_beams: 1,
        do_sample: false,
      });
      const translated = String(out?.[0]?.translation_text || "").trim();
      if (!translated) throw new Error("translation engine returned empty text");
      json(res, 200, {
        text: translated,
        source_language: src,
        target_language: tgt,
        engine: "m2m100",
        latency_ms: Math.round(performance.now() - started),
      });
      return;
    }
    json(res, 404, { error: "not found" });
  } catch (e) {
    json(res, 500, { error: String(e?.message || e) });
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`M2M100 translator listening on 127.0.0.1:${PORT}`);
  console.log(`M2M100 local model root: ${LOCAL_ROOT}`);
});
