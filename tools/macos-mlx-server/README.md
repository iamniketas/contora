# Contora MLX Server

This directory contains the tracked MLX transcription server used by the macOS app.
The app installs `contora_mlx_server.py` and `result_safety.py` into the discovered
shared MLX toolkit before starting it.

Crash-safety guarantees:

- recursively replaces `NaN`, `+Inf`, and `-Inf` with JSON `null`;
- validates the response envelope before handing it to FastAPI;
- atomically persists `asr.json`, `diarization.json`, and `result.json` under
  `$CONTORA_MLX_RESULTS_ROOT/<job-id>/`;
- persists `job.json` and reloads unfinished jobs after a backend restart, reusing
  compatible ASR and diarization checkpoints;
- serves the persisted `result.json` bytes;
- stores a structured `failure.json` and keeps completed checkpoints on failure.

The macOS client uses the persistent job API:

- `POST /v1/transcription/jobs` creates a job and returns `202`;
- `POST /v1/transcription/jobs/from-file` claims a capability-bound WAV from
  `$CONTORA_MLX_HANDOFF_ROOT` without copying it into an HTTP multipart body;
- `GET /v1/transcription/jobs/{job_id}` reports the current stage, monotonic progress,
  processed/total audio seconds, elapsed time, and ETA;
- `GET /v1/transcription/jobs/{job_id}/result` returns the persisted result;
- `DELETE /v1/transcription/jobs/{job_id}` requests cancellation.

The handoff endpoint accepts only a 32–64 character lowercase hexadecimal token.
The corresponding `<token>.json` descriptor and `<token>.wav` must resolve to regular,
non-symlink files inside the Contora handoff directory. A descriptor cannot authorize
an arbitrary path. The app writes both files with owner-only permissions.

Completed artifacts are retained until the result has been fetched, then removed after
`CONTORA_MLX_JOB_TTL_SECONDS` (seven days by default). Failed and cancelled diagnostics
use `CONTORA_MLX_TERMINAL_JOB_TTL_SECONDS` (30 days by default).

ASR progress is observed from Whisper's internal seek loop, without splitting the
recording into independent requests. Diarization progress uses pyannote's pipeline hook.
ETA uses a robust rolling rate over recent processed-audio samples and stays hidden until
the observation window is stable. Duration-normalized ASR, diarization, and merge timings
are saved in `hardware-profiles.json` per hardware/model/mode and weight later jobs.

The macOS client atomically stores the local-session/server-job association in
`Application Support/Contora/PendingTranscriptionJobs`. After an app restart it starts
the managed backend, reattaches to the same server job, and immediately resumes polling
its real phase rather than creating a duplicate transcription.

Run lightweight tests with:

```bash
python3 -m unittest discover -s tools/macos-mlx-server/tests -v
```

Run the route-level test with the shared MLX Python environment used by the server.
Use `sync-app-scripts.sh` after editing either Python source file.
