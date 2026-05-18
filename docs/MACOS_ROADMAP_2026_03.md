# Contora macOS Roadmap Update (2026-05)

## Goal

Bring the native macOS app from a working MVP to a dependable daily-use build that is ready for broader internal testing and then packaging.

For macOS, "feature-complete enough" now means:
- reliable local capture for `Microphone`, `System Audio`, and `System + Microphone`,
- local-first transcription through the shared transcription backend,
- session browsing and transcript review with speaker-aware editing,
- stable storage/session artifacts,
- clear operational diagnostics and a believable path to packaging.

## Current State

### Implemented now

- Native menu bar app on SwiftUI/AppKit.
- Dashboard and Settings windows.
- Capture modes:
  - `Microphone`
  - `System Audio`
  - `System + Microphone`
- Recording persistence to session storage.
- Storage policy:
  - `WAV only`
  - `WAV + M4A`
  - `M4A only`
- Audio import flow that registers external files without copying media by default.
- Video import flow that registers external files and defers `ffmpeg` audio extraction until transcription preparation.
- Session library and native session detail screen.
- Transcript/session artifact persistence.
- Speaker/segment parsing from transcript artifacts.
- Background transcription queue:
  - queued,
  - preparing,
  - transcribing,
  - completed,
  - failed,
  - cancelled.
- Session review/editing:
  - transcript edits,
  - speaker rename,
  - re-transcribe from session detail.
- Shared transcription config consumption from the local shared backend contract.
- Backend support:
  - `whisper_http`
  - `mlx_openai_http`
- Shared MLX toolkit discovery and lifecycle actions.
- Runtime diagnostics:
  - backend probe,
  - shared runtime paths,
  - config/catalog visibility,
  - ffmpeg availability.
- Long-session hardening work:
  - lower-RAM buffering,
  - scratch-file capture storage.

### Verified after sync with GitHub `v0.5.1`

- Local branch is rebased on top of official `origin/main` / `v0.5.1`.
- macOS package still builds with `swift build`.
- Latest local macOS-only commits remain on top of the official branch:
  - shared MLX auto-start fixes,
  - session-detail `Transcribe` button,
  - transcription enabled by default.

### Sprint A implementation status

- The primary macOS window is now a three-column workspace for capture, recording/transcription state, and session review.
- Normal recording flow no longer depends on the Dictator-style floating ticker overlay.
- Recording start/stop, import audio/video, capture scope, storage policy, active devices, recordings folder, backend status, and the recent session list are visible from the workspace.
- Audio/video import and stopped recordings do not auto-transcribe; users explicitly start or queue transcription from the center workspace controls.
- Imported audio/video files are not copied into Contora's recordings folder. Contora stores a session manifest that points at the original file path, and stores transcript artifacts next to the manifest.
- Heavy work for imported media is deferred until `Start Transcribing`: audio decode/resample and video audio extraction happen during the preparation step, not during file selection.
- Background transcription is represented as a queue with active, queued, completed, failed, and cancelled states; recording can start while a transcription job is running.
- Active transcription can be stopped from the workspace.
- The current UI no longer shows fake estimated progress/ETA for backends that do not emit progress events. It shows an indeterminate progress state until server-side progress exists.
- Transcript review is segment-first with timestamp ranges, inline text editing, speaker rename propagation, unsaved-change state, and per-segment playback.
- Primary workflow controls are intentionally centralized in the center column. The review column no longer duplicates `Start Transcribing`.
- Session browsing now supports search, status filtering, and sorting for larger libraries.
- The shared transcription server contract now defines optional NDJSON progress events while retaining backward compatibility with the existing JSON response.
- Real-device validation is tracked in `docs/MACOS_VALIDATION_CHECKLIST_2026_05.md`.

### Current next actions

1. Implement real server-side transcription progress events in the shared Whisper/MLX backend.
   - Emit percent, processed seconds, elapsed, remaining, and audio-seconds-per-second over NDJSON.
   - Wire macOS UI to consume those events instead of indeterminate progress.
2. Validate the new import-reference model.
   - Missing/moved original files need a clear recovery message.
   - Optional future action: "copy into Contora archive" as an explicit user command, not default import behavior.
3. Run the real-device recording matrix in `docs/MACOS_VALIDATION_CHECKLIST_2026_05.md`.
4. Add archive/export tooling for sessions and transcripts.

## Target UX Specification

### Primary interaction model

- The macOS app must be usable from its main window.
- The tray icon may remain as a secondary convenience entrypoint, but it must not be the primary place where recording is controlled.
- A user should be able to:
  - open the main window,
  - choose what to record,
  - start recording,
  - watch recording progress,
  - stop recording,
  - transcribe and review the result,
  without needing tray-only actions.

### Overlay policy

- The floating overlay/ticker in the top-right corner should not appear in Contora during normal recording/transcription flow.
- Treat the current overlay behavior as an inherited Dictator-style artifact, not as intended Contora UX.
- Recording/transcription state must be visible in the main window instead of an overlay.

### Main window structure

- The main window should become the real Contora workspace.
- The target structure should follow the Windows mental model:
  - left column: recording and capture controls,
  - center column: recording state and current session controls,
  - right column: transcript/session review workspace.
- The current session library can remain accessible, but it should not replace the primary recording workspace.
- On open, the main window must default to the recording workspace, not to session history/library.
- Before any recording/transcription is available, the transcript/review area should remain empty or show a lightweight placeholder.
- After recording is saved and transcribed, that same right-side area should become the review surface for the active session.

### Left column: capture and source controls

- Show the recordings/output folder directly in the main window.
- Show which audio sources are currently active before recording starts.
- Show recording destination/session context clearly.
- Show capture scope controls in the main window.
- At minimum expose:
  - `Microphone`
  - `System Audio`
  - `System + Microphone`
- If macOS supports usable device-level control, expose:
  - input device selection,
  - output/system source selection.
- If device-level selection is not feasible in the current macOS capture architecture, the UI must explicitly state:
  - that system-wide audio is being captured,
  - whether microphone is included,
  - what the active mode means in practical terms,
  - which output device the system is currently using,
  - which microphone/input device is currently active.
- The user should never need to infer from hidden settings what audio is being recorded.
- Application-level capture selection is a desirable future direction, but it is not required for the first macOS UI sprint.
- Separate-track recording for system audio and microphone is a possible future enhancement, but it is not required to unblock the current parity sprint.

### Center column: recording controls and live state

- Main window must contain first-class controls for:
  - `Start Recording`
  - `Stop Recording`
  - `Import Audio`
  - `Import Video`
- `Pause/Resume` is not required for the first sprint.
- Show live recording state in-window:
  - current status,
  - elapsed time,
  - file/session being written,
  - whether transcription is enabled,
  - current backend if relevant.
- While recording is active, the main window should continue to reflect progress rather than disappearing behind tray/overlay behavior.
- Starting recording from the tray, if kept, must still update the main window state cleanly and should not replace the main experience with an overlay.

### Right column: transcript and session review

- Transcript must not be presented as a single wall of text as the primary review surface.
- The primary transcript view should be row/segment based.
- Each transcript row should contain:
  - start timestamp,
  - end timestamp,
  - play/seek control for that range,
  - speaker label/name,
  - editable text field for correction.
- Playback must use the exact row timestamps so the user can listen to the corresponding fragment and verify recognition quality by ear.
- Speaker rename must propagate consistently across all affected segments.
- Raw full transcript should not be kept as a primary in-app editing surface.
- The purpose of the app UI is transcript correction and review, not plain TXT viewing.
- The review column should avoid duplicated recording/transcription controls; workflow CTAs live in the center column.

### Session review behavior

- After recording/transcription/import, the user should land in a review flow that feels continuous with recording.
- The app should make it obvious:
  - which session is active,
  - whether it has audio only or transcript available,
  - whether it is currently transcribing,
  - whether edits are unsaved.
- Transcription/re-transcription should be controlled from the center workspace controls. The review column should not duplicate primary workflow CTAs.
- Save changes should be explicit and visible.

### Tray role after redesign

- Tray menu can keep convenience actions:
  - open main window,
  - quick start/stop,
  - open recordings folder,
  - quit.
- Advanced or primary workflow controls should not live only in tray.
- Capture source and session review should be main-window concerns first.

## Gap Analysis

### Resolved in Sprint A

- Main-window recording controls are implemented.
- Capture source selection is in the main workspace.
- The floating overlay/ticker is removed from normal recording/transcription flow.
- The main window opens as a primary workspace rather than a session-library-only view.
- Segment-first transcript review and per-segment playback are implemented.
- Raw transcript editing is no longer the primary in-app review surface.
- Session search/filter/sort is implemented.
- Import is now a reference/registration flow, not an implicit media-copy or transcription flow.

### Remaining product gaps

- Long-call capture needs scenario validation on real apps and devices.
- Server-side transcription progress is still missing; macOS can only show indeterminate progress without backend events.
- Missing or moved external files for imported sessions need guided recovery.
- Archive/export tooling is still missing for larger session libraries.
- Runtime/model management UX is still mostly diagnostic/operator-oriented.
- Structured post-processing pipeline surfaced in macOS UI.
- Packaging/distribution/update flow for end users.

### Known technical polish items

- Expand smoke/regression coverage for session import and re-transcription flows.

## Recommended Priorities

### Priority 1: Main-window parity with Windows

Status: implemented for the current Sprint A scope.

- The app now has a proper primary workspace.
- The main window opens directly into recording/review workflow.
- Recording start/stop and capture source controls are in the main window.
- The overlay/ticker is removed from normal workflow.
- The app displays current microphone and system output context instead of pretending to have full Windows-style device targeting.
- Tray remains a secondary convenience surface.

### Priority 2: Recording reliability

- Validate `System Audio` and `System + Microphone` across:
  - Telegram
  - Zoom
  - Google Meet
  - Slack
  - browser playback
- Test device changes during runtime:
  - headphones connect/disconnect,
  - microphone switch,
  - aggregate device edge cases.
- Verify long sessions:
  - 10 min
  - 30 min
  - 60+ min
- Confirm storage policy behavior and artifact cleanup for each mode.

### Priority 3: Transcript review workflow completeness

- Segment rows, timestamp ranges, inline editing, speaker rename propagation, unsaved state, and per-segment playback are implemented.
- Keep validating transcript, speakers, and playback position sync on real imported/recorded sessions.
- Make failed transcription/import states easier to recover from without restarting the app.

### Priority 4: Shared backend operability

- Basic backend status, active backend/model/endpoint, and MLX toolkit actions are visible in the workspace/settings.
- Next required backend work is real progress streaming and clearer recovery when the backend is unavailable.

### Priority 5: Productization foundation

- Better permission onboarding for microphone and screen recording.
- Improve macOS-specific error messages and recovery guidance.
- Define packaging path:
  - unsigned internal app bundle first,
  - then signed/distributed build.

## Sprint Proposal

## Sprint Goal

Make the macOS build feel like a real Contora app rather than a tray utility: users should be able to open the main window, control recording there, understand what is being captured, and review transcript segments in a structured, editable form.

### Sprint A: Recommended next sprint

1. Build the real primary window for recording workflow.
   - Replace or expand the current floating dashboard/ticker into a proper main workspace.
   - Make this the default window shown when the user opens Contora.
   - Put `Start Recording` / `Stop Recording` in the main window.
   - Put capture source controls in the main window.
   - Remove overlay-first behavior from Contora.
   - Show the active recordings folder in the main window.
   - Show which audio sources/devices are active before recording starts.
   - Show recording/transcription progress in the main window instead of relying on the overlay.
2. Add transcript-oriented session detail UX.
   - Render transcript as rows/segments, not a wall of text.
   - Show timestamp ranges per row.
   - Add per-row playback action.
   - Keep text editable inline for correction.
   - Keep speaker rename available from the same review surface.
   - Remove raw full transcript as a primary editing area.
3. Decide and implement audio control messaging.
   - If macOS cannot yet offer Windows-style device picking, state clearly what audio scope is being captured.
   - In that fallback mode, show the current system output target and current microphone/input target in the UI.
   - If device selection is feasible, expose it in the main window.
4. Harden recording validation and diagnostics.
   - Run the real-app capture matrix.
   - Log/triage failures by source mode and app.
   - Improve user-facing error/status text for missing permissions and unavailable backend.
5. Tighten shared backend workflow.
   - Surface backend state clearly in the UI.
   - Confirm auto-start/start-stop/check flows for MLX toolkit.
   - Make re-transcribe behavior reliable from existing sessions.
6. Close technical debt that blocks confidence.
   - Fix or isolate the `AVAssetExportSession` concurrency warning.
   - Refresh stale macOS docs to match the current app.

### Sprint A deliverables

- A tester can open the main window and start/stop recording there without using the tray menu.
- The main window opens directly into the recording workspace rather than session history.
- A tester can see what capture mode is active from the main window.
- A tester can see which sources/devices are currently active and which folder will receive the recording.
- A tester no longer sees the Dictator-style overlay during normal Contora recording flow.
- A tester can record and save a real meeting on macOS without losing audio.
- A tester can import audio/video, transcribe, and re-transcribe from the session screen.
- A tester can see transcript rows with timestamps and inline editing instead of a single text wall.
- A tester can click a transcript segment and hear the corresponding audio.
- A tester does not need a separate raw transcript editor inside the app.
- The app explains missing permission/backend problems in-app.
- The team has a short validation report for supported capture scenarios.

## Backlog After Sprint A

### Sprint B candidates

- Server-side transcription progress events and macOS client consumption.
- Missing external-file recovery for imported sessions.
- Runtime/model management UI.
- Better device-specific audio controls if macOS capture APIs allow them cleanly.
- Optional separate-track recording for system audio and microphone.
- Optional application-level audio-source targeting if macOS APIs allow a product-quality implementation.
- Better archive organization and export options.
- Background post-processing and structured outputs.
- Internal packaging flow for non-developer testers.

### Later product milestones

- Signed macOS app distribution.
- Update mechanism.
- More polished onboarding and recovery flows.
- Semantic retrieval/project layer on top of session artifacts.

## Apple Silicon Transcription Quality Track

### Why this needs a dedicated follow-up track

- The current macOS architecture depends on Apple Silicon-friendly local backends, especially MLX-based ones.
- In practice, some transcription runs can produce hallucinated tails, repeated phrases, or nonsensical fragments even when the main part of the transcript is correct.
- These failures should be treated as a product-quality problem in the transcription pipeline, not only as isolated model noise.

### Failure patterns to explicitly watch for

- Sudden repeated short phrases that were likely never spoken.
- Long repetitive tails at the end of transcription.
- Hallucinated filler text appearing after meaningful speech has already ended.
- Degraded quality on mixed `System + Microphone` recordings.
- Worse behavior on silence, noisy endings, overlapping speech, or low-SNR audio.

### Likely causes to investigate

- Backend-specific decoding behavior in `mlx_openai_http` versus `whisper_http`.
- Poor handling of silence/no-speech regions.
- Repetition loops caused by backend decoding settings.
- Audio-quality degradation from mixing microphone and system audio into one mono stream.
- Chunk accumulation behavior in optional streaming transcription mode.
- Missing application-side validation before saving suspicious transcripts as final output.

### Required optimization and mitigation work

1. Benchmark backend quality on the same macOS recordings.
   - Compare `mlx_openai_http` and `whisper_http` on identical files.
   - Track hallucination rate, repetition rate, latency, and edit effort.
2. Tune backend decoding behavior for safer defaults.
   - Prefer deterministic decoding where possible.
   - Investigate backend support for stricter thresholds, VAD, and anti-repetition settings.
3. Add transcript sanity checks in the app pipeline.
   - Detect repeated-phrase tails.
   - Detect suspicious repetition density.
   - Flag likely-bad transcripts instead of silently treating them as good output.
4. Add fallback behavior for suspicious transcripts.
   - Re-run transcription via a safer backend when output looks hallucinated.
   - Prefer quality over speed for Contora’s archive/review use case.
5. Evaluate the recording mix strategy.
   - Check whether `System + Microphone` should keep the current mixed mono path.
   - Investigate whether alternate preprocessing or multi-track preservation improves recognition quality.
6. Review optional streaming mode separately.
   - Ensure streaming text accumulation cannot amplify repetitions or duplicate chunk content.
   - Keep streaming clearly secondary to high-quality final transcription.

### Product requirement for this track

- Contora on Apple Silicon should optimize for reliable final transcripts, not merely fast local inference.
- A slower but more stable backend/path is acceptable if it materially reduces hallucinations in saved session transcripts.

## What This Changes From The Old Roadmap

- macOS is no longer a "skeleton"; it already has import, session library, diagnostics, storage policy, and review flows.
- The biggest Sprint A UX gap has been addressed: the main window now functions as the primary recording/transcription/review workspace.
- The next sprint should focus on real backend progress, external-file recovery for imported sessions, capture validation, archive/export flows, and packaging groundwork.
