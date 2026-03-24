# Contora macOS App (Skeleton)

This directory contains the native macOS client skeleton for Contora:

- `SwiftUI` for UI structure.
- `AppKit` integration for menu bar (`NSStatusItem`).
- Permissions bootstrap for microphone and accessibility.
- Real microphone capture via `AVAudioEngine`.
- System audio capture foundation via `ScreenCaptureKit`.

## Current Scope

- Menu bar app with checkable menu items.
- Dashboard window with runtime state and permission controls.
- Settings window skeleton.
- Start/stop recording captures real audio buffers.
- Capture source modes: `Microphone`, `System Audio`, `System + Microphone`.
- Recorded audio is saved locally as WAV in Application Support.
- Transcription path is optional and can use the shared local Whisper/MLX server.
- Added foundation for local `faster-whisper` process execution.
- Shared runtime path strategy for model reuse with Dictator.

## Run

```bash
cd apps/macos
swift run
```

For production development, open the package in Xcode and run as a macOS app target.

## Next Milestones

1. Stabilize long-call capture (10-60 min) for `System + Microphone` mode.
2. Add import, diarization UI, and session review features from the Windows version.
3. Add storage policy and compressed archive format alongside WAV.
