# macOS Speech Runtime Migration

Date: 2026-08-22

This change implements the final runtime stage of the Apple Silicon transcription
plan. It does not modify an installed copy of Contora and does not publish a release.

## Runtime contract

The managed backend is installed at:

```text
~/Library/Application Support/NiketasAI/runtime/speech-runtime/
```

`ContoraMacSpeechRuntime-arm64.tar.gz` must contain:

- relocatable Python 3.12;
- MLX/MLX Audio and the local job server;
- torch/pyannote plus the pinned fallback diarization assets;
- optional, feature-gated FluidAudio/Core ML assets;
- `runtime-manifest.json` with `runtimeId = speech-runtime`.

The launcher sets `PYTHONHOME` and `PYTHONPATH` exclusively from this directory.
It does not read the old `faster-whisper-xxl` or `mlx-audio` directories.
Downloaded and bundled archives require a matching SHA-256 sidecar and are checked
for unsafe archive paths before extraction.

## App migration

- New settings default to managed MLX Turbo.
- `faster_whisper_process` remains only as a decoding tombstone and is rewritten
  to `mlx_openai_http` in schema 2.0.
- The legacy process service, installer, model downloader, resource script, UI,
  and model-catalog discovery are absent from the macOS target.
- The server launches as part of transcription/recovery and stops five minutes
  after the global server job queue becomes idle. The server-side watchdog also
  handles the case where Contora exits while a persistent job is still finishing.
- Backend launch status is refreshed every two seconds while health startup is pending.

## Legacy cleanup

Contora never deletes the shared legacy runtime automatically. Settings diagnostics
offer an explicit move to Trash only after checking:

- the path is the exact non-symlink `faster-whisper-xxl` directory;
- Dictator is not installed;
- no running command references the runtime;
- no small Dictator configuration file references the runtime.

Any audit uncertainty blocks cleanup. Moving to Trash requires a second confirmation
and remains recoverable.

## Release gate

Before publishing a macOS release:

1. build the speech runtime with `tools/macos-mlx-runtime/build-runtime.sh`;
2. verify it with `tools/macos-mlx-runtime/verify-runtime-archive.sh`;
3. run Swift debug/release builds and the migration/client smoke tests;
4. run the MLX server unit suite;
5. package, sign, notarize, and test the app without an existing shared runtime;
6. attach the app, speech runtime, and checksum to the same GitHub release.

`publish-github-release.sh` refuses to publish without a speech runtime unless the
maintainer explicitly sets `CONTORA_RELEASE_SKIP_SPEECH_RUNTIME=1`.
