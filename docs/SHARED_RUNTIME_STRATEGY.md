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
- `speech-runtime/`
  - relocatable Python 3.12
  - MLX speech server and dependencies
  - approved diarization dependencies/assets
- `whisperkit-models/`
- `llm/`

`faster-whisper-xxl/` and `mlx-audio/` are legacy locations. Contora does not
read them after the speech-runtime migration and never removes shared data
automatically.

Also:
- `model-catalog.json`

## Environment Variables

- `NIKETAS_SHARED_RUNTIME_ROOT` (optional override root)
- `CONTORA_MACOS_SPEECH_RUNTIME_ARCHIVE`
- `CONTORA_MACOS_SPEECH_RUNTIME_URL`

## Implementation in this repo

1. `.NET` path resolver updated:
- `src/AudioRecorder.Services/Transcription/WhisperPaths.cs`
- now resolves platform-aware executable and shared macOS root.

2. macOS app path resolver added:
- `apps/macos/Sources/ContoraMac/SharedRuntimePaths.swift`

3. Managed speech runtime and server lifecycle:
- `apps/macos/Sources/ContoraMac/SharedMLXServerToolkit.swift`

## Installer/Updater Contract

For both apps:
1. Check canonical shared root.
2. If the self-contained runtime exists and its manifest is valid: reuse.
3. If missing: download once into shared root.
4. Register env vars for both app processes.

## Future Local LLM Extension

Use the same root with versioned namespaces:
- `runtime/speech-runtime/...`
- `runtime/llm/gguf/...`
- `runtime/llm/onnx/...`

This avoids per-app bundling and keeps installers small.

## Shared Model Catalog

macOS shared reuse should cover more than one backend.

The shared runtime now also defines a catalog file:

- `~/Library/Application Support/NiketasAI/runtime/model-catalog.json`

Its role is to describe discovered/shared resources across providers such as:

- `whisperkit`
- `mlx-audio`
- `ollama`

This is the direction for `DictatorMac` + `ContoraMac`: both apps should eventually consume the same shared catalog instead of treating model discovery as app-private logic.

## Migration

- Keep existing Windows paths untouched.
- Decode old macOS backend settings and rewrite them to managed MLX Turbo.
- Keep the legacy runtime untouched until the user explicitly requests cleanup.
- Before cleanup, audit Dictator installation/configuration and running process references.
