# Contora Apple Silicon transcription benchmark

This harness compares complete, pinned ASR and diarization candidates under the
same corpus, process, cache, and resource-measurement rules. A fast candidate is
not a winner until it passes the predeclared quality gate in
`corpus/contora-ru-golden-v1.template.json`.

## Reproducibility contract

- Every candidate records its engine version, exact model revision, command,
  input SHA-256, host profile, cache state, wall time, process-tree RSS, swap
  growth, and thermal warnings.
- `ps` process-tree RSS does not include every Metal/Core ML allocation in
  unified memory. It is reported together with system memory pressure and swap,
  never interpreted as total accelerator memory by itself.
- Run 1 is a fresh process with the current OS filesystem/model cache (cold
  application process). Run 2 is an immediate fresh-process repeat and is
  labelled `warm-os-cache`. The harness does not claim to purge macOS caches.
- Private recordings, human annotations, models, logs, and raw predictions are
  ignored by Git. Only manifests, hashes, policy, and the redacted fixed report
  are versioned.
- `performance-only` corpora cannot be passed to `score`; this prevents an ASR
  output from accidentally being treated as ground truth.
- A real run requires AC power and at least 20% battery. Power is rechecked
  during execution. The complete process group is stopped if AC disconnects,
  swap grows by more than 4 GiB, or system free memory stays below 10% for
  three samples. Safety stops are persisted as failed runs with a reason and
  stop the whole remaining benchmark queue.

## Runtime setup

Requirements: Apple Silicon, macOS 14+, Xcode command-line tools, ffmpeg, and
Python 3.11+. Python 3.12 is recommended.

```sh
cd tools/macos-transcription-benchmark
CONTORA_BENCH_BOOTSTRAP_PYTHON=/path/to/python3.12 ./setup-runtime.sh
export CONTORA_BENCH_RUNTIME_ROOT="$PWD/.runtime"
.runtime/python/bin/python download-models.py --root .runtime/models --skip-gated
```

Community-1 and the legacy pyannote models require accepted Hugging Face terms
and an `HF_TOKEN`. Model downloads are pinned and receive a
`.contora-model-revision` marker. The Swift FluidAudio adapter is pinned through
`Package.swift`/`Package.resolved`; it refuses a missing or mismatched model
marker rather than downloading an unpinned fallback.

Community-1 is isolated in a second venv with `pyannote.audio==4.0.7`, PyTorch
2.11, and the matching TorchAudio/TorchCodec releases. It cannot share the
legacy 3.4.0 baseline venv: Community-1 was introduced by pyannote.audio 4.x and
depends on the 4.x result/runtime stack.

Some relocatable release Python frameworks need explicit overrides. A normal
venv does not:

```sh
export CONTORA_BENCH_PYTHONHOME=/path/to/Python.framework/Versions/3.12
export CONTORA_BENCH_EXTRA_PYTHONPATH=/path/to/site-packages
```

## Corpus preparation and annotation

Convert each source once to canonical mono PCM and keep it private:

```sh
mkdir -p .local-corpus/audio .local-corpus/references
ffmpeg -i source.m4a -ac 1 -ar 16000 -c:a pcm_s16le .local-corpus/audio/sample.wav
shasum -a 256 .local-corpus/audio/sample.wav
```

Put the exact hash and measured duration in the corpus manifest. Human-reviewed
references must follow `corpus/reference.example.json` and the rules in
`corpus/ANNOTATION.md`. The checked-in template deliberately points at absent
private references; it is not itself proof that annotation is complete.

## Run and score

Run commands from this directory so the package imports resolve:

```sh
.runtime/python/bin/python benchmark.py validate \
  --corpus corpus/contora-ru-performance-v1.json \
  --engines engines.apple-silicon.json --verify-audio

.runtime/python/bin/python benchmark.py run \
  --corpus corpus/contora-ru-performance-v1.json \
  --engines engines.apple-silicon.json \
  --output results/performance --repetitions 2

.runtime/python/bin/python benchmark.py performance-report \
  --corpus corpus/contora-ru-performance-v1.json \
  --runs results/performance/runs.json \
  --output-json results/performance/report.json \
  --output-markdown results/performance/report.md

.runtime/python/bin/python benchmark.py score \
  --corpus corpus/contora-ru-golden-v1.template.json \
  --runs results/quality/runs.json --output results/quality/scores.json

.runtime/python/bin/python benchmark.py report \
  --corpus corpus/contora-ru-golden-v1.template.json \
  --scores results/quality/scores.json \
  --output-json results/quality/report.json \
  --output-markdown results/quality/report.md
```

Run unit tests with:

```sh
python3 -m unittest discover -s tests -v
```

## Current caveats

- `mlx-audio==0.3.1` initializes `_alignment_heads` but reads
  `alignment_heads` when word timestamps are enabled. Its adapter applies and
  records a narrowly scoped public alias; the installed runtime is untouched.
- FluidAudio 0.9.1 currently needs Swift 5 language mode when compiled by a
  Swift 6 toolchain because unrelated upstream ASR sources do not pass strict
  Swift 6 concurrency checks.
- A single before/after system swap delta is noisy. Raw periodic samples are
  retained; the quality gate uses median edge levels only for runs of at least
  ten minutes, and the release gate requires the hour-long trace to show no
  sustained growth or memory-pressure failure. An unambiguous growth above
  4 GiB fails immediately even on a shorter run.
