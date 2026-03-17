# Changelog

All notable changes to the Contora project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.4.0] - 2026-03-18

### Added
- **AI-generated session title**: after transcription Ollama (same model) auto-generates a short 3–7 word title for the session. Falls back to the filename if Ollama is unavailable.
- **Manual rename**: pencil icon button on each session card opens an inline ContentDialog to rename the session; the new name is persisted in the database immediately.
- **Outline link in session card**: after publishing to Outline the session card shows a clickable "Open in Outline" hyperlink. The full document URL is stored in the database so links survive app restarts.
- **Unified model selector**: Whisper model ComboBox on the main page is dynamically populated from the installed models list; the active model is shared with Settings → Models where an "Active" badge and "Use" button let you switch models without re-entering the main page.
- **Semantic search (passive)**: BGE-M3 embeddings via Ollama are computed after each transcription and stored as float32 BLOBs (sqlite-vec-compatible layout). Hybrid FTS5 + cosine-similarity search is wired up but acts as a silent upgrade path — the UI search box still works even when Ollama is down.

## [0.3.7] - 2026-03-06

### Fixed
- **Auto mode now actually works**: in "auto" device mode faster-whisper no longer attempts CUDA on incompatible GPUs. Hardware diagnostics run at startup and resolve "auto" to the correct device ("cpu" or "cuda") before any transcription starts. Users with old NVIDIA cards (GT 220, Fermi, etc.) or AMD GPUs will automatically use CPU mode — no manual setting required.
- Device info row on main page now shows "Auto → CPU" or "Auto → GPU (CUDA)" so the user sees exactly what will be used.

## [0.3.6] - 2026-03-06

### Added
- **Hardware diagnostics** (`HardwareDiagnosticsService`): detects GPU, CPU, RAM and recommends the best Whisper model and device (CUDA/CPU).
- **Settings → Engines**: hardware info card showing GPU (name + VRAM), CPU (name + cores + GHz), RAM, recommended device/model, and a warning for incompatible GPUs (old NVIDIA, AMD).
- **Device mode setting** (Auto / GPU (CUDA) / CPU) in Settings → General, persisted across sessions.
- **CPU fallback**: when device mode is set to CPU, faster-whisper runs with `--device cpu --compute_type int8`.
- **Custom install path**: user can change the faster-whisper install folder before download; the path is saved in settings.
- **Download speed & ETA**: runtime and model downloads now show MB/s and estimated time remaining.
- **`tiny` model** added to model selector everywhere.
- **Cancel transcription**: the "Transcribe" button transforms into "Stop transcription" mid-run; clicking it cancels cleanly with no error dialog.
- **Device info row** on main page (above Transcribe button) showing current device mode and selected model.
- **Timestamp button styling**: rounded corners, visible background, auto-width column — timestamps like "1:00:07" are no longer clipped.

### Fixed
- **VRAM detection on 32-bit process**: previous approaches (DXGI, WMI AdapterRAM) were capped at 3-4 GB on x86 builds. Fixed by spawning 64-bit PowerShell via `Sysnative` so `HardwareInformation.MemorySize` (REG_QWORD) is read without WOW64 truncation. nvidia-smi is now located via known paths (Sysnative/System32/NVSMI) rather than relying on PATH.
- **CPU/RAM not shown in diagnostics**: added `Win32_Processor` and `Win32_ComputerSystem` queries; now displays name, core count, GHz and total RAM.
- **PowerShell multiline scripts broken**: switched to `-EncodedCommand` (Base64 Unicode) — no more escaping/newline issues.
- **Device mode not applied at startup**: `_deviceMode` is now loaded before `CreateTranscriptionService` is called in the constructor.
- **Cancelled transcription showed error dialog**: service now re-throws `OperationCanceledException`; UI catches it silently and shows "Transcription stopped".
- **Progress stats frozen after completion**: `TranscriptionDetailsGrid` is now explicitly collapsed in the UI after transcription finishes.
- **"Transcription saved in backup" confusing message**: renamed to "Saved (Ollama not available)" to clarify Ollama is simply not running.

### Changed
- Device mode selector removed from main page (was duplicating Settings); main page now shows a read-only device info row instead.
- All UI strings are in English.

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
