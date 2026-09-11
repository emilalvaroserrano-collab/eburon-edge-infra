# Eburon Edge Infra

Canonical Android ARM64 appliance source for the Eburon Dual Translator.

## v0.3.0 release

- `dist/EburonEdge-v0.3.0.apk` — Android launcher for the localhost appliance
- `dist/eburon-edge-termux-arm64-v0.3.0.zip` — canonical Termux runtime package
- `dist/SHA256SUMS` — release integrity hashes

## Final one-command Termux installer

Paste this exact command into Termux on the Android ARM64 device:

```bash
curl -fsSL "https://raw.githubusercontent.com/emilalvaroserrano-collab/eburon-edge-infra/11e11210de7b62126cef14ce0684ed21bca09cb7/install.sh?cb=$(date +%s)" | bash
```

This installer is pinned to the immutable v0.3.0 release package and verifies the package SHA-256 before extraction and provisioning.

Core runtime:
- whisper.cpp STT on `127.0.0.1:8852`
- M2M100 translation-only WebAssembly on `127.0.0.1:8851`
- Supertonic 3 primary TTS on `127.0.0.1:8853`
- Starlette gateway/PWA on `127.0.0.1:8850`
- Piper is catalogue-only until an isolated Android runtime is verified
- no Qwen, llama.cpp, cloud inference, or external frontend CDN

The installer is fail-closed: `OFFLINE READY` is printed only after translation, Supertonic WAV, browser-codec STT, WebSocket, and frontend smoke tests pass.

The Android APK is a thin launcher/WebView shell for `http://127.0.0.1:8850`; provision and run the Termux appliance first. The current CI APK is installable for appliance testing but is not Play Store production-signed.
