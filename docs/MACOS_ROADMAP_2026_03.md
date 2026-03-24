# Contora macOS Roadmap Update (2026-03)

## Goal

Bring macOS Contora to practical feature parity with the current Windows version where it matters:
- capture calls and other system audio locally,
- transcribe locally,
- support speaker-aware review workflows,
- prepare the archive/context pipeline for future semantic features.

This roadmap also aligns macOS with the shared local transcription server strategy used across Contora and Dictator.

## Reference Baseline: Current Windows Version

The current Windows repository already includes:
- system audio + microphone recording,
- audio import,
- video import with ffmpeg-based audio extraction,
- local transcription with faster-whisper-xxl,
- speaker diarization,
- transcript editing and speaker renaming,
- timestamp-based playback navigation,
- runtime/model download and update flows,
- post-processing session pipeline foundation.

## Status Review

### Completed on macOS

- Native menu bar app skeleton in SwiftUI/AppKit.
- Source selection in UI:
  - `Microphone`
  - `System Audio`
  - `System + Microphone`
- System capture via `ScreenCaptureKit`.
- Microphone capture via `AVAudioEngine`.
- Mixed recording pipeline with WAV persistence.
- Shared runtime path design for common model storage.
- Shared config design for common local transcription server access.
- Manual health probe for Whisper/MLX endpoints.
- Batch transcription through the shared local server:
  - `whisper_http`
  - `mlx_openai_http`
- Audio import UI and session pipeline integration.
- Video import UI with ffmpeg-based audio extraction.
- Native session library window for browsing local sessions.
- Structured session artifact foundation with manifest-first session metadata.
- Diarization-aware session model with speaker/segment parsing from transcript artifacts.
- Session review/editor for transcript correction and speaker renaming.
- Storage policy for `WAV only`, `WAV + M4A`, and `M4A only`.
- Runtime/server diagnostics for shared backend, shared runtime, and ffmpeg availability.
- Long-session capture hardening via lower-RAM buffering and scratch-file capture storage.
- Shared MLX toolkit interop for macOS local server lifecycle alongside Dictator.

### In Progress on macOS

### Not Implemented Yet on macOS

- Transcript segment timeline with playback navigation.
- Runtime/model management UI equivalent to Windows settings.
- Search/archive/project layer.
- Semantic post-processing and structured context extraction.
- Packaging/distribution flow for end users.

## Recommended Delivery Order

### Phase 1: Stabilize Recording MVP

- Validate `System Audio` and `System + Microphone` on:
  - Telegram
  - Zoom
  - Google Meet
  - Slack
  - browser playback
- Add recordings folder access from tray.
- Add storage policy:
  - `WAV only`
  - `WAV + compressed archive`
  - `delete WAV after compression`
- Move archival format from raw-only `WAV` toward `M4A` for disk efficiency.

### Phase 2: Shared Local Transcription

- Make Contora consume the shared `transcription-server.json`.
- Wire batch transcription to the selected backend:
  - `whisper_http`
  - `mlx_openai_http`
- Keep backend ownership outside the app:
  - one local server process,
  - one shared runtime/model store.
- Add explicit backend state in UI:
  - reachable,
  - warming,
  - model unavailable,
  - transcribing.

### Phase 3: Windows Core Feature Parity

- Import audio files.
- Import video files and extract audio through ffmpeg.
- Persist transcript artifacts per session.
- Add diarization-aware transcript model.
- Add speaker rename UX.
- Add segment list with timestamps and jump-to-playback.

### Phase 4: Contora-Specific Value Layer

- Session detail view:
  - raw transcript,
  - cleaned transcript,
  - speakers,
  - metadata.
- Structured session artifact:
  - machine-readable metadata,
  - human-readable transcript export,
  - incremental enrichment stages.
- Session pipeline for post-processing:
  - cleaning,
  - summaries,
  - decisions,
  - action items,
  - risks.
- Optional background batch refinement after initial transcript.
- Archive organization and future semantic retrieval.

### Phase 5: Productization

- Stable packaged macOS build.
- First-run permission onboarding.
- Runtime/server diagnostics page.
- Error reporting and recovery flow.
- Installer/update story.

## Updated Completion Map Against Old Roadmap

### Old item: native macOS skeleton
- Status: done

### Old item: system-level capture foundation
- Status: done for MVP
- Note: needs validation and storage polish before calling production-ready

### Old item: shared runtime strategy
- Status: done at architecture/config level
- Note: execution path still needs end-to-end integration in Contora

### Old item: transcription
- Status: done for batch transcription
- Note: still needs UX hardening, diagnostics, and long-session validation

### Old item: MLX integration
- Status: done through shared local server contract
- Note: MLX remains externalized as the shared backend owner, not embedded directly in Contora

## Proposed Next Engineering Slice

1. Finish storage UX:
   add `Open Recordings Folder`, storage format policy, optional `M4A` compression.
2. Implement batch transcription through the shared local server.
3. Add imported file flow (audio first, video second).
4. Add structured session artifact output and a native macOS session screen.
5. Port diarization/session viewer pieces from Windows into that session screen.
