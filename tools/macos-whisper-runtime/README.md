# Contora macOS Whisper Runtime Artifact

Builds the Contora-managed macOS `faster-whisper-xxl` runtime archive used by `Set Up Local Whisper`.

This is the macOS equivalent of the Windows flow: users should download a Contora-prepared runtime artifact, not create Hugging Face accounts or manage pyannote tokens.

## Build

On the build/release machine, set an organization Hugging Face token that has accepted access to:

- `pyannote/speaker-diarization-3.1`
- `pyannote/segmentation-3.0`
- `pyannote/wespeaker-voxceleb-resnet34-LM`

Then run:

```bash
export HF_TOKEN="hf_..."
tools/macos-whisper-runtime/build-runtime.sh
```

Or keep the token in a temporary file outside the repository:

```bash
printf '%s' 'hf_...' > /tmp/contora_hf_token
HF_TOKEN_FILE=/tmp/contora_hf_token tools/macos-whisper-runtime/build-runtime.sh
rm -f /tmp/contora_hf_token
```

The output is written to:

```text
artifacts/macos-whisper-runtime/dist/
```

The archive layout is:

```text
faster-whisper-xxl/
  faster-whisper-xxl
  bin/contora_fw_transcribe.py
  venv/
  pyannote/
    speaker-diarization-3.1/
    segmentation-3.0/
    wespeaker-voxceleb-resnet34-LM/
  runtime-manifest.json
```

## Local App Install Test

The packaged app can install `ContoraMacWhisperRuntime-<arch>.tar.gz` directly from its resources. For local development, point the installer at a local archive:

```bash
export CONTORA_MACOS_WHISPER_RUNTIME_ARCHIVE="/absolute/path/to/ContoraMacWhisperRuntime-arm64.tar.gz"
```

Then run Contora macOS and press `Set Up Local Whisper`.

## No User Tokens

Do not embed the Hugging Face token in the app. It is only for the build machine to prepare the runtime artifact. The shipped app receives only the resulting archive.
