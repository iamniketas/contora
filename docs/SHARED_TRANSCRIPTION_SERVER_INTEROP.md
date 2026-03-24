# Shared Transcription Server Interop (Contora + Dictator)

## Objective

Both apps use the same local transcription server and the same model/runtime resources.

This document is intentionally scoped to the macOS versions of `Contora` and `Dictator`.
It is not the cross-platform contract for Windows and Linux.

## Local Server Runtime

- MLX OpenAI-compatible server endpoint: `http://127.0.0.1:8000/v1/audio/transcriptions`
- Whisper fallback endpoint: `http://127.0.0.1:5500/transcribe`

Server process is shared (single instance on localhost), not embedded separately per app.

## Why macOS Flow Is Different

- macOS should prefer one warm local backend process on Apple Silicon instead of separate embedded runtimes in each app.
- `MLX` is a first-class backend on macOS, but not the baseline assumption for Windows/Linux.
- Shared paths and process ownership are built around macOS application conventions in `~/Library/Application Support`.
- Product roles differ:
  - `DictatorMac` is optimized for low-latency capture/transcribe actions.
  - `ContoraMac` is optimized for session capture, archive, review, and context building.

## Platform Boundary

- macOS:
  shared localhost server + shared config + shared runtime/models
- Windows:
  separate runtime/distribution strategy, centered on Windows-native packaging and current Whisper runtime flow
- Linux:
  separate runtime/distribution strategy, potentially different inference backend choices

## Shared Config File

Path:
- `~/Library/Application Support/NiketasAI/runtime/transcription-server.json`
- Override via env: `NIKETAS_SHARED_SERVER_CONFIG`

Schema (v1.0):

```json
{
  "schemaVersion": "1.0",
  "activeBackend": "mlx_openai_http",
  "whisperTranscribeURL": "http://127.0.0.1:5500/transcribe",
  "mlxTranscribeURL": "http://127.0.0.1:8000/v1/audio/transcriptions",
  "mlxModelID": "mlx-community/whisper-large-v3-turbo-asr-fp16",
  "updatedAt": "2026-02-24T00:00:00Z"
}
```

## Shared MLX Toolkit

Current macOS interop also assumes a shared MLX toolkit layout outside both app bundles.

Detected toolkit shape:
- root: `/Users/n.likhachev/Documents/projects/test-dmg/shared-mlx`
- start: `bin/start-mlx-server.sh`
- stop: `bin/stop-mlx-server.sh`
- check: `bin/check-mlx.sh`
- log: `mlx-server.log`

Optional override:
- `NIKETAS_SHARED_MLX_ROOT`

This keeps MLX ownership outside `ContoraMac` and `DictatorMac` while still letting both apps coordinate around one server process.

## Beyond Endpoint Sharing

The macOS shared flow is no longer only about one localhost endpoint.

It should also converge toward:

- one shared runtime root,
- one shared model catalog,
- shared provider-specific paths for `WhisperKit`, `MLX`, and future local LLM runtimes.

## Current State in Contora

- `apps/macos` now reads/writes this shared config.
- `Settings` UI has:
  - backend selector,
  - Whisper endpoint,
  - MLX endpoint + model id,
  - save/reload,
  - backend health probe.
- `Settings` diagnostics now also detect the shared MLX toolkit and expose:
  - start,
  - stop,
  - check,
  - open log.
- Contora batch transcription now uses the selected shared backend:
  - `whisper_http`
  - `mlx_openai_http`
- Transcript artifacts are saved next to the recording session.

## Dictator Alignment

`Dictator` currently has MLX backend support in:
- `apps/macos/Sources/DictatorMac/main.swift`

To fully unify behavior, Dictator should read the same shared config file on launch and write updates back to it.

## Operational Flow

1. Start MLX server once on machine.
2. Save endpoint/model once in shared config.
3. Both apps resolve backend settings from the same file.
4. Both apps send transcription requests to the same localhost server.
5. On macOS, both apps may also rely on the same shared MLX toolkit/scripts for lifecycle operations.
