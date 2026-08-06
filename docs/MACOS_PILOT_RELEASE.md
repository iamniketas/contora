# Contora macOS Pilot Release

This release path is for a GitHub macOS build that can be used without building Contora from source.

For the non-developer installation and update handoff, use:

```text
docs/MACOS_INSTALL_AND_UPDATE_FOR_NON_DEV.md
```

## Gatekeeper Status

Unsigned pilot builds are not signed with an Apple Developer ID and are not notarized. On default macOS settings, users must explicitly allow the app on first launch:

1. Move `Contora.app` to `Applications`.
2. Open `Contora.app`.
3. If macOS blocks it, open `System Settings -> Privacy & Security`.
4. Click `Open Anyway` for Contora, then confirm `Open`.

This is acceptable for a pilot, but not for a frictionless public release. For a smoother install/update flow, build with a Developer ID Application certificate and notarize the DMG.

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

The script creates a drag-to-Applications DMG by default:

```text
artifacts/macos-pilot/Contora-macOS-<version>-<arch>-unsigned.dmg
```

The default DMG is intentionally slim and does not embed the ~483 MB compressed Python/Whisper runtime. `Set Up Local Whisper` downloads that runtime once from the matching GitHub release. This keeps the application update itself around a few megabytes and preserves an already installed runtime across app updates.

To bundle a local runtime archive inside the app:

```bash
CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE="/absolute/path/to/ContoraMacWhisperRuntime-arm64.tar.gz" \
  tools/macos-release/package-pilot.sh
```

For a local build that auto-discovers the conventional runtime artifact path, set `CONTORA_MACOS_BUNDLE_WHISPER_RUNTIME=1`.

Outputs:

```text
artifacts/macos-pilot/Contora.app
artifacts/macos-pilot/Contora-macOS-<version>-<arch>-unsigned.dmg
artifacts/macos-pilot/Contora-macOS-<version>-<arch>-unsigned.zip
artifacts/macos-pilot/SHA256SUMS
```

Disable DMG creation only for local debugging:

```bash
CONTORA_MACOS_CREATE_DMG=0 tools/macos-release/package-pilot.sh
```

Build a signed and notarized DMG:

```bash
CONTORA_VERSION=0.5.3 \
CONTORA_MACOS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
CONTORA_MACOS_NOTARIZE=1 \
CONTORA_MACOS_NOTARY_PROFILE="contora-notary" \
tools/macos-release/package-pilot.sh
```

When DMG creation is enabled, the script mounts the finished image and verifies the contained app with `codesign --verify --deep --strict`. With `CONTORA_MACOS_NOTARIZE=1`, it also submits the DMG with `notarytool` and staples the ticket.

An unsigned PKG is possible, but it is not easier for pilot users because installer packages also need a Developer ID Installer certificate for the normal trusted macOS flow.

## In-App Updates

Contora checks GitHub Releases from the macOS app settings and menu bar:

```text
Settings -> Updates -> Check for Updates
```

The updater reads `https://api.github.com/repos/iamniketas/contora/releases/latest`, compares the latest release tag with `CFBundleShortVersionString`, chooses a macOS asset for the current architecture, downloads it to `Downloads`, and opens it. Upload DMG assets with names like:

```text
Contora-macOS-0.5.3-arm64-signed.dmg
Contora-macOS-0.5.3-x86_64-signed.dmg
```

The updater prefers DMG, then PKG, then ZIP. Runtime artifacts such as `ContoraMacWhisperRuntime-arm64.tar.gz` are intentionally ignored by the app updater.

If `GITHUB_TOKEN` is available, replace the macOS app assets in the existing GitHub Release with:

```bash
export GITHUB_TOKEN="github_pat_..."
CONTORA_VERSION=0.5.2-macos-pilot tools/macos-release/publish-github-release.sh
```

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
