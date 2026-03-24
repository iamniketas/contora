# Contora macOS: System Audio Capture Architecture

## Goal

Build a native macOS capture pipeline that can record:
- system output audio (speakers/headphones),
- microphone,
- and combined call context for transcription.

## Key Constraint (macOS)

Unlike Windows WASAPI loopback, macOS does not expose one global loopback API for all output devices.
The practical native option is `ScreenCaptureKit` audio capture (requires Screen Recording permission).

## Chosen Approach

1. System audio: `ScreenCaptureKit` (`SCStream`, `capturesAudio = true`).
2. Microphone: `AVAudioEngine` input tap.
3. Merge layer: normalize both streams to mono 16kHz PCM for Whisper input.
4. Transcription: local `faster-whisper` process.

## Capture Modes

1. `System Only`
- For calls where mic is not required or captured by conferencing app output.

2. `Mic Only`
- Fallback mode when Screen Recording permission is denied.

3. `System + Mic` (primary mode)
- Capture both channels and mix down for transcript quality.

## Permissions

- Screen Recording: mandatory for system output audio via ScreenCaptureKit.
- Microphone: mandatory for direct mic capture.

On first run, onboarding must explicitly check both permissions and expose a fallback mode.

## Current Implementation in Repo

- `apps/macos/Sources/ContoraMac/SystemAudioCaptureService.swift`
  - starts/stops ScreenCaptureKit stream,
  - tracks sample buffer stats,
  - validates permission flow.

- Existing app skeleton in `apps/macos/Sources/ContoraMac/main.swift`
  - already has microphone capture path and state management baseline.

## Remaining Work (execution order)

1. Implement PCM extraction from `CMSampleBuffer` and WAV persistence in `SystemAudioCaptureService`.
2. Add mixer for `System + Mic` path (simple weighted mono mix is enough for MVP).
3. Add source picker in UI (system/mic/both).
4. Route resulting WAV into local faster-whisper process service.
5. Add end-to-end smoke test for 30s call recording on Apple Silicon.

## Why this is the right baseline

- Native and stable Apple stack, no kernel extension requirement.
- Works with local-first privacy model.
- Avoids lock-in to virtual audio drivers for first production iteration.
