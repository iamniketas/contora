# Contora macOS Speech Runtime

Build the self-contained Apple Silicon runtime used by Contora's managed speech backend:

```bash
CONTORA_SPEECH_SOURCE_VENV=/absolute/path/to/a/tested/.venv \
CONTORA_PYANNOTE_ASSETS_ROOT=/absolute/path/to/tested/assets \
  tools/macos-mlx-runtime/build-runtime.sh
```

The resulting `ContoraMacSpeechRuntime-arm64.tar.gz` contains its own relocatable
Python 3.12 framework, MLX, pyannote fallback dependencies and pinned pyannote
assets. It does not read Python, packages, or models from the legacy
`faster-whisper-xxl` runtime. Without `CONTORA_SPEECH_SOURCE_VENV`, the script
creates a clean source environment and installs the pinned dependencies. Without
`CONTORA_PYANNOTE_ASSETS_ROOT`, it fetches the model snapshot during the release
build (and honors `HF_TOKEN_FILE`).

To build a candidate runtime containing the feature-gated FluidAudio/Core ML diarizer:

```bash
CONTORA_SPEECH_INCLUDE_FLUID_ANE=1 \
CONTORA_FLUID_MODELS_ROOT=/absolute/path/to/pinned/models \
CONTORA_SPEECH_SOURCE_VENV=/absolute/path/to/a/tested/.venv \
tools/macos-mlx-runtime/build-runtime.sh
```

The model root must contain `speaker-diarization-coreml/.contora-model-revision`
pinned to `1ed7a662fdc7109e36d822db793ee6eebdaf8594`. The archive includes license notices.
Packaging the assets does not enable them: the server also requires both
`CONTORA_MLX_ENABLE_EXPERIMENTAL_ANE=1` (quality approval) and
`CONTORA_MLX_ENABLE_PARALLEL_ANE=1` (scheduler rollout). Otherwise pyannote/MPS remains
the sequential fallback.

Every release archive must pass the self-containment and import gate before upload:

```bash
tools/macos-mlx-runtime/verify-runtime-archive.sh \
  artifacts/macos-speech-runtime/dist/ContoraMacSpeechRuntime-arm64.tar.gz
```

The app requires the matching `.sha256` sidecar for both bundled and downloaded
archives and rejects path traversal entries before extraction.
