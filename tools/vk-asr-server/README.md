# Contora Corporate ASR sidecar

Private localhost backend that implements Contora's persistent transcription-job
contract. It sends canonical audio to the configured corporate ASR service and
runs local pyannote diarization on the same untrimmed timeline.

No corporate endpoint or token is stored in Git. The server binds to
`127.0.0.1:8020` by default and is intended for one approved workstation.

## Setup on the corporate Mac

```bash
cd tools/vk-asr-server
cp .env.example .env
chmod 600 .env
$EDITOR .env
./run-server.sh
```

`run-server.sh` reuses Contora's installed self-contained Python 3.12,
dependencies, and pyannote assets by default. If that runtime is not installed,
create a Python 3.11+ venv with `pip install -e ".[diarization]"` and set
`CONTORA_VK_PYTHON` to its Python executable.

Set the Contora transcription endpoint to:

```text
http://127.0.0.1:8020/v1/audio/transcriptions
```

The `/v1/audio/transcriptions` path is used only as the base URL by the current
macOS client; actual work uses `/v1/transcription/jobs/*`.

## Launch Contora Corporate

From the private repository root:

```bash
./run-corporate-dev.sh
```

The launcher reuses `SPEECH_API_TOKEN` from the existing LightningASR `.env`
when the private sidecar `.env` leaves it empty. It starts the sidecar, waits for
its health check, injects the corporate endpoint into Contora, enables local
diarization, and then launches the macOS app. Closing the app also stops the
sidecar process started by the launcher.

When the participant count is known, set **Expected speakers** in Contora's
Transcription settings. This is sent per job and prevents pyannote from splitting
one person into several small clusters. `Auto` keeps pyannote speaker counting.

To re-run only diarization and speaker attribution for a saved job, without a
second upload or VK request, use:

```bash
python -m contora_vk_server.reprocess /path/to/job --num-speakers 4
```

## Security boundary

- keep `.env` untracked and mode `0600`;
- use an approved storage backend reachable by inference;
- do not expose port 8020 beyond localhost;
- diagnostics contain no bearer token and redact URI query parameters;
- the repository has no working push URL until a private remote is explicitly added.
