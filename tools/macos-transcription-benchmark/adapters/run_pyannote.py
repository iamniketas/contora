#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.metadata
import inspect
import os
import time
from pathlib import Path

from common import atomic_write, require_model_revision


def local_legacy_config(runtime_root: Path, output_root: Path) -> Path:
    source = runtime_root / "pyannote/speaker-diarization-3.1/config.yaml"
    text = source.read_text(encoding="utf-8")
    text = text.replace(
        "segmentation: pyannote/segmentation-3.0",
        "segmentation:\n      checkpoint: "
        + str(runtime_root / "pyannote/segmentation-3.0/pytorch_model.bin"),
    )
    text = text.replace(
        "embedding: pyannote/wespeaker-voxceleb-resnet34-LM",
        "embedding:\n      checkpoint: "
        + str(runtime_root / "pyannote/wespeaker-voxceleb-resnet34-LM/pytorch_model.bin"),
    )
    target = output_root / "speaker-diarization-3.1.local.yaml"
    target.write_text(text, encoding="utf-8")
    return target


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pipeline", required=True)
    parser.add_argument("--model-id")
    parser.add_argument("--model-revision", required=True)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--token-env", default="HF_TOKEN")
    parser.add_argument("--legacy-runtime-root", type=Path)
    args = parser.parse_args()
    require_model_revision(Path(args.pipeline), args.model_revision)

    import torch
    from pyannote.audio import Pipeline

    pipeline_source = args.pipeline
    if args.legacy_runtime_root:
        pipeline_source = str(local_legacy_config(args.legacy_runtime_root, args.output.parent))
    token = os.environ.get(args.token_env)
    signature = inspect.signature(Pipeline.from_pretrained)
    kwargs = {}
    if token:
        kwargs["token" if "token" in signature.parameters else "use_auth_token"] = token
    started = time.monotonic()
    loading_started = time.monotonic()
    pipeline = Pipeline.from_pretrained(pipeline_source, **kwargs)
    pipeline.to(torch.device(args.device))
    loading = time.monotonic() - loading_started
    inference_started = time.monotonic()
    result = pipeline(str(args.audio))
    inference = time.monotonic() - inference_started
    annotation = getattr(result, "speaker_diarization", result)
    turns = []
    iterator = annotation.itertracks(yield_label=True)
    for turn, _, speaker in iterator:
        turns.append(
            {
                "start": float(turn.start),
                "end": float(turn.end),
                "speaker": str(speaker),
                "confidence": None,
            }
        )
    payload = {
        "schema_version": "1.0",
        "kind": "diarization",
        "engine": {
            "id": "pyannote",
            "version": importlib.metadata.version("pyannote.audio"),
            "model": args.model_id or args.pipeline,
            "model_revision": args.model_revision,
            "device": args.device,
        },
        "text": "",
        "segments": [],
        "words": [],
        "speaker_turns": turns,
        "timing": {
            "model_loading_seconds": loading,
            "inference_seconds": inference,
            "total_seconds": time.monotonic() - started,
        },
    }
    atomic_write(args.output, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
