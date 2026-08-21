# Contora MLX Server

This directory contains the tracked MLX transcription server used by the macOS app.
The app installs `contora_mlx_server.py` and `result_safety.py` into the discovered
shared MLX toolkit before starting it.

Crash-safety guarantees:

- recursively replaces `NaN`, `+Inf`, and `-Inf` with JSON `null`;
- validates the response envelope before handing it to FastAPI;
- atomically persists `asr.json`, `diarization.json`, and `result.json` under
  `$CONTORA_MLX_RESULTS_ROOT/<job-id>/`;
- serves the persisted `result.json` bytes;
- stores a structured `failure.json` and keeps completed checkpoints on failure.

Run lightweight tests with:

```bash
python3 -m unittest discover -s tools/macos-mlx-server/tests -v
```

Run the route-level test with the shared MLX Python environment used by the server.
Use `sync-app-scripts.sh` after editing either Python source file.
