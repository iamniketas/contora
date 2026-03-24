# Local Shared Transcription Server Plan

## Why

Contora and Dictator should not bundle separate transcription runtimes and models.
A shared localhost server reduces install size and avoids duplicate model downloads.

## MVP Topology

1. One local server process (`127.0.0.1:5500`).
2. Both apps send audio files/chunks to the same `/transcribe` endpoint.
3. Shared runtime root stores binaries and models once.

## Engine Abstraction

Server uses one engine adapter interface:
- `transcribe(audio, options) -> text + metadata`

Adapters:
- `FasterWhisperAdapter` (baseline).
- `MLXAudioAdapter` (drop-in alternative when you provide repo link and runtime details).

## App Integration

- Contora macOS capture module records WAV locally.
- App may either:
  - keep WAV only (record-only mode),
  - or send to local server when transcription is enabled.

## Next Step After You Send MLX Repo

1. Validate install/runtime path for MLX server.
2. Add `MLXAudioAdapter` implementation in shared server.
3. Add engine switch in config (`engine = faster-whisper|mlx-audio`).
4. Benchmark on same audio files and compare latency/quality.
