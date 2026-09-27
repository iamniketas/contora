# Private VK ASR integration

This repository is the private Contora distribution. Corporate ASR integration
must not be copied into the public `iamniketas/contora` repository.

## Boundary

```text
Contora macOS
  -> localhost persistent-job contract
  -> private VK ASR sidecar
       -> canonical MP3 upload
       -> corporate asynchronous ASR
       -> local pyannote diarization (parallel)
       -> overlap merge and result-v2 persistence
```

The sidecar intentionally contains no default corporate base URL. It refuses to
start a job unless endpoint, token, upload storage, and local diarization runtime
are configured on the approved workstation.

## Current first slice

- async URL-based recognition with operation polling;
- exact `operationId` polling and unique correlation IDs;
- 16 kHz mono 64 kbit/s MP3 preparation without trimming;
- local full-file pyannote diarization in parallel with remote ASR;
- deterministic attribution for word-level VAD gaps and near-tied overlaps;
- optional expected-speaker count that consolidates minor automatic clusters
  into the dominant long-lived speakers;
- persistent Contora-compatible job status/result endpoints;
- cancellation and restart-safe completed-result reads;
- redacted diagnostics with source SHA-256 and raw ASR response.

## Deliberately deferred

- approved corporate S3/presigned upload adapter (the first slice supports a
  transfer-compatible endpoint);
- forced alignment when ASR segments span multiple speakers;
- automatic sidecar installation and lifecycle management from the app;
- live corporate-network and token preflight UI;
- Windows client wiring.
