# Contora for macOS: installation and updates for a non-developer

This is the handoff path for a Mac owner who does not have Xcode, Homebrew, Python, Git, or the Contora source tree.

## What to send

Send one GitHub Releases link:

```text
https://github.com/iamniketas/contora/releases/latest
```

For Apple Silicon Macs, the owner should download the asset named like:

```text
Contora-macOS-<version>-arm64-signed.dmg
```

If the release is still an unsigned pilot, the file will be named like:

```text
Contora-macOS-<version>-arm64-unsigned.dmg
```

Do not ask the owner to download source code archives, Windows installers, `RELEASES`, `.nupkg`, or `ContoraMacWhisperRuntime-*.tar.gz`.

## First installation

1. Open the downloaded `.dmg`.
2. Drag `Contora.app` to `Applications`.
3. Open `Contora` from `Applications`.
4. If macOS blocks an unsigned pilot build, open `System Settings -> Privacy & Security`, click `Open Anyway` for Contora, then confirm `Open`.
5. When Contora asks for permissions, allow `Microphone` and `Screen Recording`.
6. In Contora, press `Set Up Local Whisper`.

The owner does not need to install Python, ffmpeg, Homebrew, Xcode, or models manually. Contora installs its local Whisper runtime from a bundled artifact when present, otherwise from the latest GitHub Release.

## Updating later

1. Open Contora.
2. Open `Settings`.
3. In `Updates`, press `Check for Updates`.
4. If a new version is available, press `Download Update`.
5. When the downloaded DMG opens, drag the new `Contora.app` to `Applications` and replace the old app.
6. Open Contora again.

Recordings, transcripts, downloaded Whisper models, and runtime files are stored in the user's Library and are not deleted by replacing `Contora.app`.

## Release checklist for the maintainer

Build the runtime artifact first when Local Whisper should work without Python:

```bash
export HF_TOKEN="hf_..."
tools/macos-whisper-runtime/build-runtime.sh
```

Build a user-facing macOS DMG:

```bash
CONTORA_VERSION=0.5.3 \
CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE="/absolute/path/to/ContoraMacWhisperRuntime-arm64.tar.gz" \
tools/macos-release/package-pilot.sh
```

For a low-friction release, use a Developer ID Application certificate and notarize:

```bash
CONTORA_VERSION=0.5.3 \
CONTORA_MACOS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
CONTORA_MACOS_NOTARIZE=1 \
CONTORA_MACOS_NOTARY_PROFILE="contora-notary" \
CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE="/absolute/path/to/ContoraMacWhisperRuntime-arm64.tar.gz" \
tools/macos-release/package-pilot.sh
```

Upload the generated DMG and `SHA256SUMS` to the GitHub Release. The in-app updater chooses the latest release asset matching the current Mac architecture and prefers DMG over PKG and ZIP.

With a GitHub token, publish or replace the generated macOS assets from the command line:

```bash
export GITHUB_TOKEN="github_pat_..."
CONTORA_VERSION=0.5.2-macos-pilot tools/macos-release/publish-github-release.sh
```
