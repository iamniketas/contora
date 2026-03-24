# Local Transcription Server Contract (Contora + Dictator)

## Purpose

A single local transcription server process used by multiple desktop apps.

## Transport

- Base URL: `http://127.0.0.1:5500`
- Content-Type: `multipart/form-data` for audio upload.
- Auth: none (localhost-only, single-user machine scope).

## Endpoints

### `GET /health`

Response:

```json
{
  "status": "ok",
  "engine": "faster-whisper|mlx-audio",
  "model": "large-v2",
  "ready": true
}
```

### `POST /transcribe`

Form fields:
- `file`: audio file (`wav`, `m4a`, `mp3`).
- `language`: optional language code (`ru`, `en`, ...).
- `task`: optional (`transcribe` by default).

Response:

```json
{
  "text": "...",
  "segments": [],
  "duration_seconds": 32.6,
  "engine": "faster-whisper",
  "model": "large-v2"
}
```

## Runtime and Model Reuse

All engines should reuse a shared runtime root:
- `~/Library/Application Support/NiketasAI/runtime/`

Subdirectories:
- `runtime/faster-whisper-xxl/...`
- `runtime/mlx-audio/...`

## Engine Strategy

- Default engine: `faster-whisper` (stable fallback).
- Optional engine: `mlx-audio` when available.
- Engine is selected by config, not app-specific code.
