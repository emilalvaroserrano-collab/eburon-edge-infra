# Eburon Edge Infra

Canonical Android ARM64 appliance source for the Eburon Dual Translator.

## v0.3.3 release

- `dist/EburonEdge-v0.3.3.apk` — Android launcher for the localhost appliance
- `dist/eburon-edge-termux-arm64-v0.3.3.zip` — canonical Termux runtime package
- `dist/SHA256SUMS` — release integrity hashes

The frontend follows the proven `mastertrans` dual-translator flow and is wired end-to-end to the local Termux backend:

`microphone → WebM/Opus → whisper.cpp → M2M100 → Supertonic 3 → automatic WAV playback → listening resumes`

The microphone is armed from a user tap so Android Chrome/WebView can start the Web Audio context reliably; subsequent turns are automatic.

### v0.3.3 translator runtime fix

Transformers.js 4.2.0 normally selects its Node backend whenever `process.release.name === "node"`. That is wrong for Termux Android because `onnxruntime-node` has no Android npm binary. v0.3.3 explicitly initializes the browser/WASM bundle in browser compatibility mode, uses single-threaded ONNX Runtime Web (the supported Node WASM configuration), serves the pinned M2M100 files from localhost, and keeps all model inference local after provisioning.

## Final one-command Termux installer

Paste this exact command into Termux on the Android ARM64 device:

```bash
curl -fsSL "https://raw.githubusercontent.com/emilalvaroserrano-collab/eburon-edge-infra/4382263add349d83d2d19404349e8101a3f1c3ee/install.sh?cb=$(date +%s)" | bash
```

The installer is pinned to the immutable v0.3.3 runtime package and verifies SHA-256 before extraction. Existing verified Whisper and M2M100 files are reused on reruns.

Core runtime:
- gateway/PWA: `127.0.0.1:8850`
- M2M100 translation-only WebAssembly: `127.0.0.1:8851`
- whisper.cpp STT: `127.0.0.1:8852`
- Supertonic 3 primary TTS: `127.0.0.1:8853`
- Piper remains catalogue-only until its runtime is isolated and verified
- Kokoro remains optional/disabled
- no Qwen, llama.cpp, cloud inference, or external frontend CDN

`OFFLINE READY` is fail-closed: it is printed only after local M2M100 translation, Supertonic WAV synthesis, browser-codec Whisper STT, WebSocket STT→translate→TTS, and frontend checks pass.

The Android APK is a thin launcher/WebView shell for `http://127.0.0.1:8850`; provision the Termux appliance first. The current CI APK is installable for appliance testing but is not Play Store production-signed.
