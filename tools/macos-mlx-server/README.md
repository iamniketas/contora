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

The macOS client uses the persistent job API:

- `POST /v1/transcription/jobs` creates a job and returns `202`;
- `GET /v1/transcription/jobs/{job_id}` reports the current stage, monotonic progress,
  processed/total audio seconds, elapsed time, and ETA;
- `GET /v1/transcription/jobs/{job_id}/result` returns the persisted result;
- `DELETE /v1/transcription/jobs/{job_id}` requests cancellation.

ASR progress is observed from Whisper's internal seek loop, without splitting the
recording into independent requests. Diarization progress uses pyannote's pipeline hook.

Run lightweight tests with:

```bash
python3 -m unittest discover -s tools/macos-mlx-server/tests -v
```

Run the route-level test with the shared MLX Python environment used by the server.
Use `sync-app-scripts.sh` after editing either Python source file.
