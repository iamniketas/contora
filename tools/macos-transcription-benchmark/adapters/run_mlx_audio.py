#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.metadata
import time
from pathlib import Path

from common import atomic_write, canonical_asr, require_model_revision


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-id", default="mlx-community/whisper-large-v3-turbo-asr-fp16")
    parser.add_argument("--model-revision", required=True)
    parser.add_argument("--language", default="ru")
    parser.add_argument("--chunk-duration", type=float, default=30.0)
    args = parser.parse_args()
    model_path = Path(args.model)
    require_model_revision(model_path, args.model_revision)

    from mlx_audio.stt.utils import load_model

    started = time.monotonic()
    model_started = time.monotonic()
    model = load_model(str(model_path))
    model_loading = time.monotonic() - model_started
    workarounds: list[str] = []
    if not hasattr(model, "alignment_heads") and hasattr(model, "_alignment_heads"):
        # mlx-audio 0.3.1 initializes _alignment_heads but timing.py reads alignment_heads.
        # Keep the tested engine immutable and bridge the upstream naming defect here.
        model.alignment_heads = model._alignment_heads
        workarounds.append("mlx-audio-0.3.1-alignment-heads-public-alias")
    inference_started = time.monotonic()
    result = model.generate(
        str(args.audio),
        verbose=None,
        chunk_duration=args.chunk_duration,
        language=args.language,
        word_timestamps=True,
    )
    inference = time.monotonic() - inference_started
    payload = canonical_asr(
        result,
        engine={
            "id": "mlx-audio",
            "version": importlib.metadata.version("mlx-audio"),
            "model": args.model_id,
            "model_revision": args.model_revision,
        },
        timing={"model_loading_seconds": model_loading, "inference_seconds": inference, "total_seconds": time.monotonic() - started},
    )
    payload["engine"]["workarounds"] = workarounds
    atomic_write(args.output, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
