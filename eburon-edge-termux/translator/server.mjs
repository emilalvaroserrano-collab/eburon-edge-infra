import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

// IMPORTANT: We deliberately use the Transformers.js browser/WASM bundle on
// Android/Termux because onnxruntime-node has no Android npm binary. The v4
// bundle still detects Node from globalThis.process at import time; if left
// visible it selects the ignored onnxruntime-node backend and `device: wasm`
// fails. Mask process only while the bundle initializes, then restore it for
// the rest of this server. This also makes model-file loading use buffers
// instead of Node's return-path fast path, which cannot return an HTTP model
// path from our localhost model server.
const NODE_PROCESS = globalThis.process;
let HF;
try {
  globalThis.process = undefined;
  HF = await import("./vendor/transformers/dist/transformers.js");
} finally {
  globalThis.process = NODE_PROCESS;
}
const { env, pipeline } = HF;

const PROC_ENV = NODE_PROCESS?.env || {};
const PORT = Number(PROC_ENV.EBURON_TRANSLATOR_PORT || 8851);
const MODEL = PROC_ENV.M2M_MODEL || PROC_ENV.EBURON_TRANSLATOR_MODEL || "huggingworld/m2m100_418M";
const REVISION = PROC_ENV.M2M_REVISION || "48f06c0fec544323fcf1546e312a617d962d3653";
const HERE = path.dirname(fileURLToPath(import.meta.url));
const LOCAL_ROOT = PROC_ENV.M2M_LOCAL_ROOT || path.join(os.homedir(), ".eburon-edge", "models", "m2m100-local");
const ORT_ROOT = path.join(HERE, "vendor", "onnxruntime-web", "dist");
const LOOPBACK = `http://127.0.0.1:${PORT}`;

env.allowLocalModels = true;
env.allowRemoteModels = false;
env.localModelPath = `${LOOPBACK}/models/`;
env.useFS = false;
env.useFSCache = false;
env.useBrowserCache = false;
env.useWasmCache = false;
try {
  env.backends.onnx.wasm.wasmPaths = `${LOOPBACK}/ort/`;
  env.backends.onnx.wasm.numThreads = 1;
  env.backends.onnx.wasm.proxy = false;
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
  if (file.endsWith(".model")) return "application/octet-stream";
  return "application/octet-stream";
}

function serveLocalFile(res, root, relative) {
  let decoded;
  try { decoded = decodeURIComponent(relative); } catch { res.writeHead(400); res.end(); return; }
  const target = safeJoin(root, decoded);
  if (!target) { res.writeHead(403); res.end(); return; }
  let stat;
  try { stat = fs.statSync(target); } catch { res.writeHead(404); res.end(); return; }
  if (!stat.isFile()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, {
    "content-type": contentType(target),
    "content-length": stat.size,
    "cache-control": "public, max-age=31536000, immutable",
  });
  fs.createReadStream(target).pipe(res);
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
      console.error("M2M100 initialization failed:\n" + initError);
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
    const u = new URL(req.url || "/", LOOPBACK);
    if (req.method === "GET" && u.pathname.startsWith("/models/")) {
      serveLocalFile(res, LOCAL_ROOT, u.pathname.slice("/models/".length));
      return;
    }
    if (req.method === "GET" && u.pathname.startsWith("/ort/")) {
      serveLocalFile(res, ORT_ROOT, u.pathname.slice("/ort/".length));
      return;
    }
    if (req.method === "GET" && u.pathname === "/health") {
      json(res, 200, {
        status: "ready",
        engine: "m2m100",
        model: MODEL,
        revision: REVISION,
        runtime: "transformersjs-web-wasm",
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
    const detail = String(e?.stack || e);
    console.error("M2M100 request failed:\n" + detail);
    json(res, 500, { error: String(e?.message || e), detail });
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`M2M100 translator listening on 127.0.0.1:${PORT}`);
  console.log(`M2M100 local model root: ${LOCAL_ROOT}`);
  console.log("Transformers.js runtime: browser/WASM compatibility mode under Termux Node");
});
