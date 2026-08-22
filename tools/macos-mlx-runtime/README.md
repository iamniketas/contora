# Contora macOS MLX Runtime

Build the Apple Silicon MLX dependency archive used by the in-app `Set Up MLX` flow:

```bash
CONTORA_MLX_SOURCE_VENV=/absolute/path/to/a/tested/.venv \
  tools/macos-mlx-runtime/build-runtime.sh
```

Without `CONTORA_MLX_SOURCE_VENV`, the script creates a Python 3.12 environment and installs the pinned, tested `mlx-audio` runtime. The archive intentionally excludes Python itself and reuses Contora's shared relocatable Python runtime.

To build a candidate runtime containing the feature-gated FluidAudio/Core ML diarizer:

```bash
CONTORA_MLX_INCLUDE_FLUID_ANE=1 \
CONTORA_FLUID_MODELS_ROOT=/absolute/path/to/pinned/models \
CONTORA_MLX_SOURCE_VENV=/absolute/path/to/a/tested/.venv \
tools/macos-mlx-runtime/build-runtime.sh
```

The model root must contain `speaker-diarization-coreml/.contora-model-revision`
pinned to `1ed7a662fdc7109e36d822db793ee6eebdaf8594`. The archive includes license notices.
Packaging the assets does not enable them: the server also requires both
`CONTORA_MLX_ENABLE_EXPERIMENTAL_ANE=1` (quality approval) and
`CONTORA_MLX_ENABLE_PARALLEL_ANE=1` (scheduler rollout). Otherwise pyannote/MPS remains
the sequential fallback.
