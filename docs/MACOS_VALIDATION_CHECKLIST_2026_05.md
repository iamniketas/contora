# Contora macOS Validation Checklist (2026-05)

## Scope

Use this checklist for real-device validation after the Sprint A workspace and transcription queue work.

## Recording Matrix

Test each capture mode:

- `Microphone`
- `System Audio`
- `System + Microphone`

Against these sources:

- Telegram call
- Zoom call
- Google Meet call
- Slack huddle/call
- Browser media playback

For each run, verify:

- The main workspace shows the selected capture mode before recording.
- The active microphone and system output labels match the current macOS devices.
- Recording starts and stops from the main workspace.
- No floating overlay/ticker appears during normal recording.
- A session is created in the recordings folder.
- Saved audio contains the expected source audio.
- Starting a background transcription does not block a new recording.

## Long Session Matrix

Run `System + Microphone` recordings for:

- 10 minutes
- 30 minutes
- 60+ minutes

For each run, verify:

- Memory use remains stable enough for continued work.
- Stop/finalize completes.
- The session artifact is readable after restart.
- Manual transcription can be queued after the recording is saved.

## Import and Transcription Queue

Validate:

- Import audio creates a session without auto-transcribing.
- Import audio does not copy the source media file into Contora's recordings folder.
- Import video creates a session without auto-transcribing and does not extract audio during file selection.
- Imported-session manifests point to the original external file path.
- `Start Transcribing` creates an active transcription job.
- The active job first reports audio preparation/decoding/resampling.
- Video sessions extract audio during transcription preparation, not during import.
- Starting a second transcription while one is active queues it.
- Completed and failed jobs remain visible in the workspace.
- Stopped/cancelled jobs remain visible in the workspace.
- `Stop Transcription` cancels the active job without closing the app.
- A new recording can start while a transcription job is active.
- Transcript artifacts are written to the correct session, not the newest recording.
- Transcript artifacts for imported external files are written next to Contora's session manifest, not next to the user's original file.
- If the original imported file is moved/deleted, the app should show a recoverable missing-file state. This recovery UX is still a follow-up item.

## Transcript Review

Validate:

- Segment rows show timestamp ranges.
- Segment play buttons play only the matching timestamp range.
- Editing segment text marks the session as unsaved.
- Renaming a speaker propagates to all matching segments.
- `Save Changes` is disabled until there are unsaved edits.
- Saved edits survive app restart.

## Backend Progress

Current macOS UI shows indeterminate progress when the shared backend returns only final JSON. It must not show fake percent, ETA, or speed.

When the backend supports `Accept: application/x-ndjson`, validate:

- Progress events update percent/ETA/speed in the workspace.
- Final `completed` events persist transcripts normally.
- `failed` events surface a recoverable error in the queue.
