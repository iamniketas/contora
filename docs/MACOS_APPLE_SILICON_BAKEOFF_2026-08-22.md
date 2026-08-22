# Apple Silicon transcription bake-off — 22 August 2026

Status: **in progress; no engine or pipeline winner selected**.

This report contains performance evidence from a MacBook Air with Apple M4 and
16 GB unified memory. The private inputs are canonical 16 kHz mono PCM; their
durations and SHA-256 hashes are versioned in the benchmark corpus manifest.
No transcript text, participant data, recording, or machine-local path is
committed.

The first run is a fresh application process with whatever filesystem/model
cache macOS currently holds. The second is an immediate fresh-process repeat and
is labelled warm OS cache. macOS caches are not forcibly purged. Wall time is
measured outside the candidate process. Process-tree RSS excludes some
Metal/Core ML unified-memory allocations, so system memory pressure and swap are
evaluated alongside it.

After a battery exhaustion incident during development, the harness now refuses
real runs unless AC power is connected and battery charge is at least 20%. It
rechecks power during execution and terminates the candidate process group when
AC disconnects, swap grows by more than 4 GiB, or free memory remains below 10%.
Any such stop also cancels all remaining repetitions/candidates in that queue.

## Pinned candidates

| Role | Engine | Runtime/model |
|---|---|---|
| ASR baseline | mlx-audio 0.3.1 | `whisper-large-v3-turbo-asr-fp16@624c19c9…` |
| ASR | mlx-whisper 0.4.3 | `whisper-large-v3-turbo@a4aaeec0…` |
| ASR control | Argmax/WhisperKit 1.1.0 | `openai_whisper-large-v3-v20240930_626MB@0f63a780…` |
| Diarization baseline | pyannote.audio 3.4.0/MPS | speaker-diarization 3.1; local installed bundle is not accepted as pinned evidence |
| Diarization | pyannote.audio 4.0.7/MPS | `speaker-diarization-community-1@3533c8cf…` |
| Diarization | FluidAudio 0.9.1/Core ML | `speaker-diarization-coreml@1ed7a662…` |

Community-1 intentionally uses a separate pyannote 4.x/PyTorch 2.11 venv. It is
not compatible with the 3.4.0 legacy baseline stack.

## Two-minute performance sanity check

These figures validate adapters and expose short-input behaviour. They are not
a quality ranking.

| Candidate | Role | Cold wall | Warm wall | Warm speed | Peak process-tree RSS | Notes |
|---|---|---:|---:|---:|---:|---|
| mlx-audio 0.3.1 | ASR | 21.327 s | 20.018 s | 5.99× | 1.94 GiB | 230 word timestamps; upstream alignment-head alias recorded |
| mlx-whisper 0.4.3 | ASR | 19.781 s | 17.861 s | 6.72× | 1.79 GiB | 230 word timestamps |
| Argmax 1.1.0 | ASR | 66.214 s | 9.674 s | 12.40× | 0.48 GiB | cold includes first Core ML load/compile; 226 words |
| pyannote 3.1/MPS | diarization | 17.337 s | 15.269 s | 7.86× | 0.81 GiB | 38 turns, 2 speakers; excluded from pinned decision |
| FluidAudio 0.9.1 | diarization | 4.940 s | 1.245 s | 96.39× | 0.29 GiB | 24 turns, 3 speakers |

The two MLX ASR candidates disagree on one normalized word out of 227
(0.44%). That is candidate disagreement, **not WER**. Their 229 exactly matched
words have 15.1 ms mean absolute boundary disagreement (median 0 ms, p95 40 ms).
Only a manual reference can say which output is correct.

All available candidates produced byte-stable semantic content between the two
runs after timings and diagnostics were excluded. System-wide cold-run swap
deltas were noisy and are retained in raw local traces; only sustained growth on
10+ minute runs is eligible for the swap quality gate.

## Fifteen-minute performance

The complete table will be regenerated from pinned runs. Results already
validated:

| Candidate | Cold wall | Warm wall | Warm speed | Semantic cold/warm |
|---|---:|---:|---:|---:|
| Argmax 1.1.0 | 71.089 s | 77.907 s | 11.55× | identical |
| FluidAudio 0.9.1 | 12.102 s | 12.029 s | 74.82× | identical |

The pinned `mlx-audio` cold run completed in 429.059 s (2.10× realtime). It also
coincided with 7.84 GiB of system-wide swap growth and memory-free pressure down
to 25%, so it already violates the 4 GiB emergency swap-growth gate. Its warm
repeat was cancelled when swap continued growing. The pinned `mlx-whisper`
process was then automatically stopped by the new safety guard after 65.447 s
when measured swap growth reached 4.04 GiB; it is correctly recorded as failed,
not as a timing result. Further ML measurements are suspended until the machine
has a clean low-swap baseline. Failed records from an earlier misconfigured
Python path are retained locally as failed and are not reported as measurements.

## Quality gate and blockers

No quality winner is selected because the following required evidence is not
yet available:

1. The private Contora corpus still needs word-by-word human transcription,
   exact word/speaker boundaries, overlap markup, and independent review. ASR
   output is explicitly forbidden from being promoted to `golden`.
2. Hugging Face access conditions have not been accepted for the pinned
   Community-1 and legacy pyannote model artifacts on this machine. Community-1
   is therefore blocked, not silently omitted.
3. The 15-minute pinned MLX runs and 56–60-minute thermal/resource runs are not
   complete.
4. Native ASR word timestamps have not yet been compared with a Russian forced
   alignment pass against manual word boundaries.

The predeclared gate requires WER/CER within 0.5 absolute percentage points of
the MLX baseline, DER and speaker-attributed WER no worse than pinned
pyannote/MPS, no drop in name/number recall or punctuation F1, identical
cold/warm semantic results, peak process-tree RSS below 12 GiB, no thermal
   warning, no individual swap jump above 4 GiB, and no sustained swap growth
   above 0.5 GiB.

## Current decision

FluidAudio is the leading **performance candidate** for Core ML/ANE
diarization, and Argmax is the leading warm-performance ASR control on the
short/medium inputs completed so far. Neither is a product choice. Integration
behind a default-on path remains prohibited until the manual DER/SA-WER and
hour-long gates pass. Pyannote/MPS remains the product fallback baseline.
