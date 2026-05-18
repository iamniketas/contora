# Contora macOS Handoff (2026-05-08)

## Current Product State

- macOS has a native three-column primary workspace:
  - left: capture scope, active devices, recordings folder;
  - center: recording controls, import, transcription queue, backend status, recent sessions;
  - right: transcript/session review.
- Primary workflow controls live in the center column. The review column is for review/editing and should not duplicate `Start Recording` or `Start Transcribing`.
- The old floating overlay/ticker is no longer part of normal Contora workflow.
- Tray/menu bar actions remain secondary conveniences.

## Recording

- `Microphone`, `System Audio`, and `System + Microphone` modes are exposed in the workspace.
- Contora-created recordings are stored in Contora's recordings folder and follow the WAV/M4A retention policy.
- Stopped recordings do not auto-transcribe. The user explicitly starts transcription.

## Import

- Importing audio/video registers an external file as a session.
- Import does not copy the user's media file into Contora storage.
- Import does not decode, resample, transcribe, or extract audio.
- Contora stores a `*.session.json` manifest in the recordings folder with a reference to the original file path.
- Transcript artifacts for imported external files are stored next to the Contora manifest, not next to the user's original media file.
- Follow-up needed: if the original imported file is moved/deleted, show a guided missing-file recovery flow.

## Transcription

- Transcription is manual and queue-based.
- Queue states: `queued`, `preparing`, `transcribing`, `completed`, `failed`, `cancelled`.
- Active transcription can be stopped without quitting the app.
- A recording can start while a transcription job is active.
- Shared backend selection now covers:
  - `mlx_openai_http` for the warm MLX server flow;
  - `whisper_http` for the shared localhost fallback;
  - `faster_whisper_process` for local Faster-Whisper/Whisper-XXL execution.
- The local Faster-Whisper path now has a one-click `Set Up Local Whisper` flow:
  - user chooses a Whisper model;
  - app switches to `faster_whisper_process`;
  - app installs/repairs the runtime when needed;
  - app downloads the selected model when needed;
  - app saves shared config, refreshes diagnostics/catalog, and probes readiness.
- Advanced controls still expose separate runtime install, model download, runtime folder, and release links for troubleshooting.
- Runtime install for macOS uses a shared Python venv wrapper under `~/Library/Application Support/NiketasAI/runtime/faster-whisper-xxl/`.
- The generated `faster-whisper-xxl` wrapper installs/uses `faster-whisper`, `pyannote.audio`, and `soundfile`, accepts the app's current Whisper arguments, and emits timestamped speaker rows.
- User-facing Hugging Face token setup was rejected as product direction. macOS should match Windows: ship/download a Contora-managed runtime artifact where diarization assets are already available. The current wrapper only uses a bundled local pyannote model path and falls back to one speaker when that bundle is absent.
- Runtime artifact builder lives in `tools/macos-whisper-runtime/`:
  - `build-runtime.sh` creates `ContoraMacWhisperRuntime-<arch>.tar.gz`;
  - `fetch_pyannote.py` pulls gated pyannote assets using an organization/build-machine HF token;
  - `contora_fw_transcribe.py` rewrites pyannote config to local bundled model paths at runtime.
- macOS `Set Up Local Whisper` can install a prepared artifact bundled in the app resources, from `CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE`, or from `CONTORA_MACOS_WHISPER_RUNTIME_URL`; Python assembly remains a developer fallback when no artifact is configured.
- Heavy work for imported media happens only after `Start Transcribing`:
  - audio decode/resample;
  - video audio extraction via `ffmpeg`;
  - backend transcription.
- Current shared backend responses do not provide real progress. The macOS UI must not fake percent, ETA, or speed.
- The shared contract now defines optional NDJSON progress events for a future backend implementation.

## Review

- Transcript review is segment-first.
- Rows show timestamp ranges, speaker labels, editable text, and per-segment playback.
- Speaker rename propagates across matching segments.
- `Save Changes` is enabled only when there are unsaved edits.
- Raw transcript is not the primary editing surface.

## Implemented Support Features

- Session search, status filter, and sorting.
- Backend status panel in the workspace.
- MLX toolkit actions are available from workspace/settings.
- Manual validation checklist lives in `docs/MACOS_VALIDATION_CHECKLIST_2026_05.md`.

## Next Engineering Tasks

1. Publish the Contora macOS Whisper runtime artifact:
   - confirm pyannote redistribution/license terms for the chosen distribution channel;
   - sign/notarize or otherwise integrity-protect the archive;
   - bundle it in the `.app` resources or upload it to Contora/GitHub Releases/a controlled CDN;
   - set the production runtime URL only if the archive is not bundled.
2. Validate the artifact installer on a clean Apple Silicon machine:
   - install from bundled `.app` resources;
   - install from `CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE`;
   - install from `CONTORA_MACOS_WHISPER_RUNTIME_URL`;
   - confirm existing `_models` survives runtime replacement;
   - confirm diarized output format against real multi-speaker audio.
3. Implement server-side transcription progress events and consume them in macOS.
4. Add missing-file recovery for imported external sessions.
5. Run real-device capture validation:
   - Telegram,
   - Zoom,
   - Google Meet,
   - Slack,
   - browser playback.
6. Validate long recordings:
   - 10 minutes,
   - 30 minutes,
   - 60+ minutes.
7. Add archive/export tooling for sessions and transcripts.
8. Improve first-run permission onboarding and recovery messaging.
9. Continue Apple Silicon transcription quality work:
   - compare MLX vs Whisper,
   - detect repeated/hallucinated transcript tails,
   - add safer fallback behavior.
