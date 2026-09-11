// Eburon translation-only server.
//
// IMPORTANT: this process intentionally runs under Deno, not Node.js.
// Transformers.js 4.x has a dedicated Deno web-runtime path which selects
// ONNX Runtime Web without pretending Node is a browser. Android/Termux does
// not have a supported onnxruntime-node npm binary, so Deno + ORT Web/WASM is
// the supported runtime shape for this appliance.

const PORT = Number(Deno.env.get("EBURON_TRANSLATOR_PORT") || "8851");
const MODEL = Deno.env.get("M2M_MODEL") || Deno.env.get("EBURON_TRANSLATOR_MODEL") || "huggingworld/m2m100_418M";
const REVISION = Deno.env.get("M2M_REVISION") || "48f06c0fec544323fcf1546e312a617d962d3653";
const HOME = Deno.env.get("HOME") || "/data/data/com.termux/files/home";
const LOCAL_ROOT = Deno.env.get("M2M_LOCAL_ROOT") || `${HOME}/.eburon-edge/models/m2m100-local`;
const HERE_URL = new URL("./", import.meta.url);
const HERE = decodeURIComponent(HERE_URL.pathname).replace(/\/$/, "");
const ORT_ROOT = `${HERE}/vendor/onnxruntime-web/dist`;
const ORT_MJS_URL = new URL("./vendor/onnxruntime-web/dist/ort-wasm-simd-threaded.jsep.mjs", import.meta.url).href;
const LOOPBACK = `http://127.0.0.1:${PORT}`;
const ORT_WASM_URL = `${LOOPBACK}/ort/ort-wasm-simd-threaded.jsep.wasm`;

const HF = await import("./vendor/transformers/dist/transformers.js");
const { env, pipeline } = HF;

env.allowLocalModels = true;
env.allowRemoteModels = false;
env.localModelPath = `${LOOPBACK}/models/`;
env.useFS = false;
env.useFSCache = false;
env.useBrowserCache = false;
env.useWasmCache = false;

// Use the local Emscripten module factory from file:, but serve the WASM bytes
// from loopback HTTP. This avoids Node's unsupported http: ESM import and also
// avoids relying on fetch(file://...), while keeping every runtime byte local.
env.backends.onnx.wasm.wasmPaths = {
  mjs: ORT_MJS_URL,
  wasm: ORT_WASM_URL,
};
env.backends.onnx.wasm.numThreads = 1;
env.backends.onnx.wasm.proxy = false;

let translator = null;
let initPromise = null;
let initError = null;

function json(status, obj) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function safeLocalPath(root, relative) {
  let decoded;
  try { decoded = decodeURIComponent(relative); } catch { return null; }
  if (!decoded || decoded.includes("\0") || decoded.startsWith("/")) return null;
  const parts = decoded.split("/");
  if (parts.some((p) => !p || p === "." || p === "..")) return null;
  return `${root.replace(/\/+$/, "")}/${parts.join("/")}`;
}

function contentType(file) {
  if (file.endsWith(".json")) return "application/json";
  if (file.endsWith(".wasm")) return "application/wasm";
  if (file.endsWith(".mjs") || file.endsWith(".js")) return "text/javascript";
  return "application/octet-stream";
}

async function serveFile(root, relative) {
  const target = safeLocalPath(root, relative);
  if (!target) return new Response("Forbidden", { status: 403 });
  try {
    const file = await Deno.open(target, { read: true });
    const stat = await file.stat();
    if (!stat.isFile) { file.close(); return new Response("Not found", { status: 404 }); }
    return new Response(file.readable, {
      status: 200,
      headers: {
        "content-type": contentType(target),
        "content-length": String(stat.size),
        "cache-control": "public, max-age=31536000, immutable",
      },
    });
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return new Response("Not found", { status: 404 });
    console.error(`File serve failure for ${target}:`, e);
    return new Response("File error", { status: 500 });
  }
}

async function init() {
  if (translator) return translator;
  if (initPromise) return initPromise;
  initPromise = (async () => {
    try {
      const t = await pipeline("translation", MODEL, {
        dtype: "q8",
        device: "wasm",
        local_files_only: true,
      });
      translator = t;
      initError = null;
      return t;
    } catch (e) {
      initError = String(e?.stack || e);
      initPromise = null;
      console.error("M2M100 initialization failed:\n" + initError);
      throw e;
    }
  })();
  return initPromise;
}

async function handler(req) {
  const u = new URL(req.url);
  try {
    if (req.method === "GET" && u.pathname.startsWith("/models/")) {
      return await serveFile(LOCAL_ROOT, u.pathname.slice("/models/".length));
    }
    if (req.method === "GET" && u.pathname.startsWith("/ort/")) {
      return await serveFile(ORT_ROOT, u.pathname.slice("/ort/".length));
    }
    if (req.method === "GET" && u.pathname === "/health") {
      return json(200, {
        status: "ready",
        engine: "m2m100",
        model: MODEL,
        revision: REVISION,
        runtime: "deno-transformersjs-web-wasm",
        deno_version: Deno.version.deno,
        process_ready: true,
        model_loaded: translator !== null,
        model_root: LOCAL_ROOT,
        ort_mjs: ORT_MJS_URL,
        ort_wasm: ORT_WASM_URL,
        init_error: initError,
        thinking: false,
      });
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
      return json(200, { status: "ready", model_loaded: true, sample });
    }
    if (req.method === "POST" && u.pathname === "/v1/translate") {
      let b;
      try { b = await req.json(); } catch { return json(400, { error: "invalid json" }); }
      const text = String(b?.text || "").trim();
      const src = String(b?.source_language || b?.src_lang || "en").split(/[-_]/)[0].toLowerCase();
      const tgt = String(b?.target_language || b?.tgt_lang || "nl").split(/[-_]/)[0].toLowerCase();
      if (!text) return json(400, { error: "text is required" });
      if (src === tgt) return json(200, { text, source_language: src, target_language: tgt, engine: "m2m100", latency_ms: 0 });
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
      return json(200, {
        text: translated,
        source_language: src,
        target_language: tgt,
        engine: "m2m100",
        latency_ms: Math.round(performance.now() - started),
      });
    }
    return json(404, { error: "not found" });
  } catch (e) {
    const detail = String(e?.stack || e);
    console.error("M2M100 request failed:\n" + detail);
    return json(500, { error: String(e?.message || e), detail });
  }
}

Deno.serve({ hostname: "127.0.0.1", port: PORT, onListen: () => {
  console.log(`M2M100 translator listening on 127.0.0.1:${PORT}`);
  console.log(`M2M100 local model root: ${LOCAL_ROOT}`);
  console.log(`ORT module factory: ${ORT_MJS_URL}`);
  console.log(`ORT WASM bytes: ${ORT_WASM_URL}`);
  console.log(`Runtime: Deno ${Deno.version.deno} + Transformers.js Web/WASM`);
}}, handler);
