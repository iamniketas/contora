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
- Manual transcription workflow through the shared local Whisper/MLX server.
- Background transcription queue with active/queued/completed/failed/cancelled states.
- Active transcription can be stopped from the workspace.
- Local `faster-whisper` process backend with a one-click setup flow, model selection, runtime install/repair, model download, and diarization toggle.
- Product direction for diarization is a Contora-managed runtime artifact with bundled/prepared pyannote assets, matching the Windows flow without per-user Hugging Face token setup.
- Runtime artifact builder: `../../tools/macos-whisper-runtime/`.
- Runtime installer accepts a bundled `ContoraMacWhisperRuntime-<arch>.tar.gz`, `CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE`, or `CONTORA_MACOS_WHISPER_RUNTIME_URL` for installing a prepared archive.
- Shared runtime path strategy for model reuse with Dictator.
- Audio/video import registers external files without copying media into Contora storage.
- Video audio extraction with `ffmpeg` is deferred until transcription starts.
- Session library, segment-first transcript editing, speaker rename workflow, and per-segment playback.
- Session search, status filtering, and sorting for larger local libraries.
- Runtime/backend diagnostics and shared MLX toolkit controls in Settings and the workspace.
- Exact transcription percent/ETA requires server-side progress events; without them the workspace shows an indeterminate progress state.

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

1. Add server-side transcription progress events so the workspace can show exact percent/ETA instead of client-side estimates.
2. Build and validate a Contora-managed macOS Faster-Whisper runtime artifact with prepared diarization assets.
3. Add recovery UX for imported sessions whose original external files were moved or deleted.
4. Stabilize real-world capture and long-call behavior for `System Audio` and `System + Microphone`.
5. Add archive/export tooling for larger session libraries.

Manual validation checklist: `../../docs/MACOS_VALIDATION_CHECKLIST_2026_05.md`.
Current handoff/status note: `../../docs/MACOS_HANDOFF_2026_05.md`.
