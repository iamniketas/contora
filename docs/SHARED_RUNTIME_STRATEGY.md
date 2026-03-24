# Shared Runtime Strategy (Contora + Dictator)

## Problem

`Contora` and `Dictator` both need local transcription models/tooling, but downloading model/runtime twice wastes disk and increases install size.

## Target

Single shared runtime location for:
- whisper binary/runtime,
- model directories,
- future local LLM runtimes.

## Canonical Path (macOS)

`~/Library/Application Support/NiketasAI/runtime/`

Inside:
- `faster-whisper-xxl/`
  - `faster-whisper-xxl`
  - `_models/faster-whisper-large-v2/...`
- `whisperkit-models/`
- `mlx-audio/`
- `llm/`

Also:
- `model-catalog.json`

## Environment Variables

- `NIKETAS_SHARED_RUNTIME_ROOT` (optional override root)
- `CONTORA_WHISPER_EXE`
- `CONTORA_WHISPER_ROOT`
- `CONTORA_WHISPER_MODELS_DIR`
- `CONTORA_WHISPER_MODEL_LARGE_V2_DIR`

## Implementation in this repo

1. `.NET` path resolver updated:
- `src/AudioRecorder.Services/Transcription/WhisperPaths.cs`
- now resolves platform-aware executable and shared macOS root.

2. macOS app path resolver added:
- `apps/macos/Sources/ContoraMac/SharedRuntimePaths.swift`

3. Local process transcription service added:
- `apps/macos/Sources/ContoraMac/FasterWhisperProcessTranscriptionService.swift`

## Installer/Updater Contract

For both apps:
1. Check canonical shared root.
2. If runtime exists and checksum is valid: reuse.
3. If missing: download once into shared root.
4. Register env vars for both app processes.

## Future Local LLM Extension

Use the same root with versioned namespaces:
- `runtime/faster-whisper-xxl/...`
- `runtime/llm/gguf/...`
- `runtime/llm/onnx/...`

This avoids per-app bundling and keeps installers small.

## Shared Model Catalog

macOS shared reuse should cover more than one backend.

The shared runtime now also defines a catalog file:

- `~/Library/Application Support/NiketasAI/runtime/model-catalog.json`

Its role is to describe discovered/shared resources across providers such as:

- `whisperkit`
- `faster-whisper`
- `mlx-audio`
- `ollama`

This is the direction for `DictatorMac` + `ContoraMac`: both apps should eventually consume the same shared catalog instead of treating model discovery as app-private logic.

## Migration

- Keep existing Windows paths untouched.
- On macOS first run, if app-private runtime exists, move/symlink into shared root.
- Maintain backward compatibility with current `CONTORA_*` variables.
