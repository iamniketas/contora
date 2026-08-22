# Contora macOS App

This directory contains the native macOS client for Contora:

- `SwiftUI` for UI structure.
- `AppKit` integration for menu bar (`NSStatusItem`).
- Permissions bootstrap for microphone and accessibility.
- Real microphone capture via `AVAudioEngine`.
- System audio capture foundation via `ScreenCaptureKit`.

## Current Scope

- Native primary workspace with capture, recording, transcription, and review columns.
- Menu bar app with secondary convenience actions.
- Settings window.
- Start/stop recording captures real audio buffers.
- Capture source modes: `Microphone`, `System Audio`, `System + Microphone`.
- Recorded audio is saved locally in session storage with configurable WAV/M4A retention.
- Managed local transcription workflow through the self-contained speech runtime.
- MLX results are finite-number sanitized and checkpointed before the HTTP response; failed attempts use a separate `.failed.json` and never overwrite the last successful transcript.
- Background transcription queue with active/queued/completed/failed/cancelled states.
- Active transcription can be stopped from the workspace.
- MLX transcription reports live model-loading, ASR, diarization, merge, percentage, and ETA status through a persistent local job API.
- The backend starts automatically for transcription jobs and stops after an idle timeout.
- The legacy `Local Whisper / faster-whisper` backend is decoded only for settings migration and is not selectable or shipped in the macOS target.
- The runtime contains relocatable Python, MLX and the approved diarization fallback assets; no per-user Hugging Face token is required.
- Runtime artifact builder: `../../tools/macos-mlx-runtime/`.
- Runtime installer accepts a bundled `ContoraMacSpeechRuntime-<arch>.tar.gz`, `CONTORA_MACOS_SPEECH_RUNTIME_ARCHIVE`, or `CONTORA_MACOS_SPEECH_RUNTIME_URL`.
- Legacy shared runtime cleanup is explicit, recoverable via Trash, and blocked when Dictator or another process may still use it.
- Shared runtime path strategy for model reuse with Dictator.
- Audio/video import registers external files without copying media into Contora storage.
- Video audio extraction with `ffmpeg` is deferred until transcription starts.
- Session library, segment-first transcript editing, speaker rename workflow, and per-segment playback.
- Session search, status filtering, and sorting for larger local libraries.
- Runtime/backend diagnostics and shared MLX toolkit controls in Settings and the workspace.
- In-app GitHub Releases update check, macOS asset download, and installer open flow.

## Run

```bash
cd apps/macos
swift run
```

If you already built it once, you can also launch the current debug build directly:

```bash
cd apps/macos
.build/debug/ContoraMac
```

For production development, open the package in Xcode and run as a macOS app target.

## Next Milestones

1. Complete the golden-corpus quality gate for the feature-gated Core ML/ANE diarizer.
2. Add recovery UX for imported sessions whose original external files were moved or deleted.
3. Stabilize real-world capture and long-call behavior for `System Audio` and `System + Microphone`.
4. Add archive/export tooling for larger session libraries.

Manual validation checklist: `../../docs/MACOS_VALIDATION_CHECKLIST_2026_05.md`.
Current handoff/status note: `../../docs/MACOS_HANDOFF_2026_05.md`.
Non-developer install/update handoff: `../../docs/MACOS_INSTALL_AND_UPDATE_FOR_NON_DEV.md`.
