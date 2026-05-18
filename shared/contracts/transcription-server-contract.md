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

Progress-capable clients may send:

- `Accept: application/x-ndjson, application/json`

When the server supports progress streaming, it should respond with newline-delimited JSON events and finish with a final `completed` event. Clients must still accept the non-streaming JSON response above for backward compatibility.

Progress event:

```json
{
  "event": "progress",
  "percent": 42,
  "processed_seconds": 137.2,
  "duration_seconds": 326.0,
  "elapsed_seconds": 18.4,
  "remaining_seconds": 25.1,
  "audio_seconds_per_second": 7.4,
  "message": "Transcribing 42%"
}
```

Completed event:

```json
{
  "event": "completed",
  "text": "...",
  "segments": [],
  "duration_seconds": 326.0,
  "engine": "faster-whisper",
  "model": "large-v2"
}
```

Failed event:

```json
{
  "event": "failed",
  "error": "Model unavailable"
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
