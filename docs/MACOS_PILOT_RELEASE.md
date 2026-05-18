# Contora macOS Pilot Release

This release path is for a GitHub pilot build that can be used without building Contora from source.

## Gatekeeper Status

This pilot is not signed with an Apple Developer ID and is not notarized. On default macOS settings, users must explicitly allow the app on first launch:

1. Move `Contora.app` to `Applications`.
2. Open `Contora.app`.
3. If macOS blocks it, open `System Settings -> Privacy & Security`.
4. Click `Open Anyway` for Contora, then confirm `Open`.

This is acceptable for a pilot, but not for a frictionless public release.

## Build Runtime Artifact

For Whisper with diarization, build the Contora-managed runtime with pyannote assets on a release machine that has a Hugging Face token with accepted access to:

- `pyannote/speaker-diarization-3.1`
- `pyannote/segmentation-3.0`
- `pyannote/wespeaker-voxceleb-resnet34-LM`

```bash
export HF_TOKEN="hf_..."
tools/macos-whisper-runtime/build-runtime.sh
```

Output:

```text
artifacts/macos-whisper-runtime/dist/ContoraMacWhisperRuntime-<arch>.tar.gz
artifacts/macos-whisper-runtime/dist/ContoraMacWhisperRuntime-<arch>.tar.gz.sha256
```

Upload both files to the same GitHub release as the macOS app. If the runtime is not bundled in the app, Contora downloads it from:

```text
https://github.com/iamniketas/contora/releases/latest/download/ContoraMacWhisperRuntime-<arch>.tar.gz
```

## Package App

```bash
tools/macos-release/package-pilot.sh
```

To bundle a local runtime archive inside the app:

```bash
CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE="/absolute/path/to/ContoraMacWhisperRuntime-arm64.tar.gz" \
  tools/macos-release/package-pilot.sh
```

Outputs:

```text
artifacts/macos-pilot/Contora.app
artifacts/macos-pilot/Contora-macOS-<version>-<arch>-unsigned.zip
artifacts/macos-pilot/SHA256SUMS
```

Create a drag-to-Applications DMG for pilot distribution:

```bash
CONTORA_MACOS_CREATE_DMG=1 tools/macos-release/package-pilot.sh
```

When DMG creation is enabled, the script mounts the finished image and verifies the contained app with `codesign --verify --deep --strict`. Outputs include:

```text
artifacts/macos-pilot/Contora-macOS-<version>-<arch>-unsigned.dmg
```

An unsigned PKG is possible, but it is not easier for pilot users because installer packages also need a Developer ID Installer certificate for the normal trusted macOS flow.

## Pilot Validation

Minimum validation before uploading:

- Launch from `Contora.app`.
- Pass first-run Gatekeeper override.
- Request microphone permission.
- Request Screen Recording permission for system audio.
- Record `Microphone`.
- Record `System Audio`.
- Record `System + Microphone`.
- Press `Set Up Local Whisper`.
- Confirm runtime installs from bundled archive or GitHub release asset.
- Confirm model download succeeds.
- Transcribe a recorded session locally.
- Confirm diarized output contains speaker labels beyond a single fallback speaker on multi-speaker audio.
