# Changelog

All notable changes to the Contora project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.3.5] - 2026-03-04

### Fixed
- Fixed model download file-locking bug: FileStream is now explicitly closed before File.Move to avoid "in use" errors.
- Fixed transcription failing with "model not found": added `--model_dir` argument pointing to the correct models root directory.
- Fixed runtime installer downloading oldest asset (r192) instead of newest: now picks the highest version number from GitHub releases.
- Fixed downloaded models not appearing in Settings > Models: added `RefreshFromDiskAsync()` that re-scans filesystem on every Settings open.

### Added
- Runtime version detection: app runs `faster-whisper-xxl --version` on startup and shows a warning if the installed version is below r245 (required for diarization).
- "Update runtime" button on MainPage that deletes the outdated runtime and downloads the latest version.

### Changed
- Settings nav label shortened from "Engines & Runtime" to "Engines" to fit the 180px nav column.

## [0.3.3] - 2026-02-28

### Added
- Automatic FFmpeg download for video import support (~140 MB, installed to LocalAppData).
- FFmpeg status indicator in the Transcription section with download button and progress.

### Changed
- Runtime, model, and FFmpeg downloads are no longer auto-started. Users must initiate them manually.
- Model download messages now show estimated size and quality level for each model.

## [0.3.2] - 2026-02-27

### Fixed
- Eliminated UI mojibake by replacing user-facing app strings with stable English labels.
- Made transcription controls visible immediately and added an explicit Whisper model selector.
- Added selectable Whisper model downloads (`small`, `medium`, `large-v2`) with persisted preference.
- Moved model storage to a shared model root (`LocalAppData\\SharedWhisperModels`) with optional Dictator path detection.
- Switched release packaging to a classic Inno Setup installer with directory selection and completion flow.

## [0.3.1] - 2026-02-27

### Added
- Transcription mode selector in UI: `Quality` and `Light`.

### Changed
- Added persisted transcription mode in local settings (`quality` / `light`).
- `Light` mode now runs Whisper without diarization for faster CPU execution on low-end machines.

### Fixed
- Improved low-spec usability by making fast mode a first-class, one-click option.

## [0.3.0] - 2026-02-27

### Added
- Video import support in the transcription flow (`.mp4`, `.m4v`, `.mov`, `.avi`, `.mkv`, `.webm`, `.wmv`).
- Automatic extraction of audio tracks to MP3 via `ffmpeg` when importing video files.

### Changed
- The transcription pipeline now accepts imported video by normalizing it to MP3 before Whisper/diarization.
- Added `ffmpeg` resolution strategy: `CONTORA_FFMPEG_EXE` environment variable, bundled runtime path, app directory, then `PATH`.

## [0.2.7] - 2026-02-27

### Fixed
- Fixed intermittent mojibake in Russian UI labels by normalizing runtime UI strings that overwrite XAML defaults.
- Added repository `.editorconfig` UTF-8 policy to prevent accidental ANSI saves for source/UI files.

### Release
- Published a Windows installer as a GitHub Release asset (`Contora-win-Setup.exe`).
- Kept Whisper runtime/model out of the installer package; runtime and model are downloaded in-app on demand.

## [0.2.6] - 2026-02-19

### Fixed
- Stabilized WinUI title bar icon application to prevent fallback to the default system icon.
- Finalized tray/title bar icon consistency in the release runtime environment.

### Changed
- Bumped the stable release version for GitHub distribution and rollback point.

## [0.2.5] - 2026-02-19

### Added
- System tray integration with actions: show/hide window, start/stop recording, pause/resume, exit.
- Minimize/close-to-tray behavior for desktop workflow.

### Changed
- Project/app branding switched to **Contora** across app metadata, docs, and release tooling.
- App title now shows `Contora 0.2.5`.
- Release packaging updated around `Contora.exe` naming and publish/release paths.

### Fixed
- Consistent app icon rendering in executable, taskbar, tray, and title bar.
- Release build/publish flow for the current branded binary.

## [0.2.2] - 2026-01-28

### Fixed
- **Critical crash on long files:** Resolved the `-1073740791` (0xC0000409) failure during transcription of 60+ minute audio. Whisper could complete transcription but crash during cleanup (pyannote/CUDA memory teardown). The app now ignores this specific cleanup crash when the output file has been produced successfully.
- **Memory pressure on large files:** Fixed memory growth caused by buffering the full Whisper output in `StringBuilder`. The app now keeps only the last 200 lines for error messages.
- **Race condition at process shutdown:** Added explicit waiting for stdout/stderr stream handlers after `WaitForExitAsync` to prevent premature completion.

### Added
- **Detailed transcription progress:** Real-time display of:
- Completion percentage
- Transcription speed (audio seconds/s)
- Elapsed transcription time
- Estimated remaining time
- Processed/total audio timeline
- **Result statistics:** After transcription completes, the UI shows:
- Character count
- Word count
- Output file size (KB)
- **Full Whisper logging:** Complete Whisper process output (stdout + stderr) is saved to `{audio_name}_whisper.log` next to the result for troubleshooting.
- **Launcher scripts:** Added `run-debug.bat`, `run-release.bat`, and `build-and-run.ps1` for quick app startup from the repository root.

### Changed
- **Whisper progress parsing:** Updated regex parsing for `faster-whisper-xxl` output with `-pp`, for example:
```text
1% |   35/4423 | 00:01<<02:22 | 30.73 audio seconds/s
```
- **Progress UI:** Simplified the interface to avoid duplicated information. The primary line shows percentage and timeline; details (elapsed, speed, remaining) are shown in dedicated fields.
- **Whisper parameters:** Removed experimental `--chunk_length` and `--compute_type` flags that caused finalization crashes. Added `-pp` (print_progress) and `--standard` for stable output formatting.

## [0.2.1] - 2026-01-23

### Added
- Transcription editing: direct editing of segment text in the UI.
- Speaker renaming via context menu (right click).
- Audio playback on timestamp click.
- Unsaved changes indicator (green checkmark / yellow dot).

### Fixed
- Transcription parsing for correct timestamp handling.
- Long path truncation in UI with tooltip support.

### Changed
- Improved interface aesthetics: compact layout without duplicate information.

## [0.2.0] - 2026-01-19

### Added
- Base UI for displaying segmented transcription.
- Diarization support via `pyannote_v3.1`.
- Speaker name editing.

## [0.1.0] - 2026-01-15

### Added
- System audio recording via WASAPI loopback.
- Microphone recording.
- Audio file import (WAV, MP3, FLAC, OGG, M4A, OPUS).
- Local transcription via `faster-whisper-xxl`.
- WAV to MP3 conversion for disk space savings.
- Base WinUI 3 interface.
- Notifications on transcription completion.
