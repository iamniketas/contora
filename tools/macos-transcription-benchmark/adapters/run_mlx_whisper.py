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
    args = parser.parse_args()
    model_path = Path(args.model)
    require_model_revision(model_path, args.model_revision)

    import mlx_whisper

    started = time.monotonic()
    result = mlx_whisper.transcribe(
        str(args.audio),
        path_or_hf_repo=str(model_path),
        language=args.language,
        word_timestamps=True,
        verbose=None,
    )
    elapsed = time.monotonic() - started
    payload = canonical_asr(
        result,
        engine={
            "id": "mlx-whisper",
            "version": importlib.metadata.version("mlx-whisper"),
            "model": args.model_id,
            "model_revision": args.model_revision,
        },
        timing={"total_seconds": elapsed, "inference_including_load_seconds": elapsed},
    )
    atomic_write(args.output, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
