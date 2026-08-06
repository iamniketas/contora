# Contora macOS MLX Runtime

Build the Apple Silicon MLX dependency archive used by the in-app `Set Up MLX` flow:

```bash
CONTORA_MLX_SOURCE_VENV=/absolute/path/to/a/tested/.venv \
  tools/macos-mlx-runtime/build-runtime.sh
```

Without `CONTORA_MLX_SOURCE_VENV`, the script creates a Python 3.12 environment and installs the pinned, tested `mlx-audio` runtime. The archive intentionally excludes Python itself and reuses Contora's shared relocatable Python runtime.
