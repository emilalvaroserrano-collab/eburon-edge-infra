# Eburon Edge Infra

Canonical Android ARM64 appliance source for the Eburon Dual Translator.

## v0.3.0 core

- whisper.cpp STT on `127.0.0.1:8852`
- M2M100 translation-only WebAssembly service on `127.0.0.1:8851`
- Supertonic 3 primary TTS on `127.0.0.1:8853`
- Starlette gateway/PWA on `127.0.0.1:8850`
- Piper is catalogue-only until an isolated Android runtime is verified
- No Qwen, llama.cpp, cloud inference, or external frontend CDN

The Termux installer is fail-closed: `OFFLINE READY` is printed only after real translation, Supertonic WAV, browser-codec STT, WebSocket, and frontend smoke tests pass.

`android/` contains the installable Eburon Edge launcher APK. It wraps the localhost appliance UI and forwards microphone permission to the WebView.
