# Eburon Edge Infra

Clean Android ARM64 Termux appliance source for the Eburon Dual Translator.

Core: whisper.cpp STT + M2M100 translation-only WASM + Supertonic 3 TTS. Services bind to localhost only. Piper/Kokoro are optional and must never replace Termux ONNX Runtime.

This repository intentionally uses one canonical source tree—no nested hotfix layers.
