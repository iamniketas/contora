#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path

from huggingface_hub import get_token, snapshot_download


MODELS = (
    {
        "repo_id": "mlx-community/whisper-large-v3-turbo-asr-fp16",
        "revision": "624c19c9af5603fa73b83bce14d4aeea96156d18",
        "directory": "mlx-whisper-large-v3-turbo-fp16",
        "allow_patterns": None,
        "gated": False,
    },
    {
        "repo_id": "mlx-community/whisper-large-v3-turbo",
        "revision": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
        "directory": "mlx-whisper-official-large-v3-turbo-fp16",
        "allow_patterns": None,
        "gated": False,
    },
    {
        "repo_id": "FluidInference/speaker-diarization-coreml",
        "revision": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
        "directory": "speaker-diarization-coreml",
        "allow_patterns": None,
        "gated": False,
    },
    {
        "repo_id": "argmaxinc/whisperkit-coreml",
        "revision": "0f63a7800b00dd0226abd051b906c246e1907482",
        "directory": "argmax-whisperkit-coreml",
        "allow_patterns": [
            "openai_whisper-large-v3-v20240930_626MB/**",
            "config.json",
            "README.md",
        ],
        "gated": False,
    },
    {
        "repo_id": "pyannote/speaker-diarization-community-1",
        "revision": "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee",
        "directory": "pyannote-community-1",
        "allow_patterns": None,
        "gated": True,
    },
    {
        "repo_id": "pyannote/speaker-diarization-3.1",
        "revision": "84fd25912480287da0247647c3d2b4853cb3ee5d",
        "directory": "pyannote-legacy/pyannote/speaker-diarization-3.1",
        "allow_patterns": None,
        "gated": True,
    },
    {
        "repo_id": "pyannote/segmentation-3.0",
        "revision": "e66f3d3b9eb0873085418a7b813d3b369bf160bb",
        "directory": "pyannote-legacy/pyannote/segmentation-3.0",
        "allow_patterns": None,
        "gated": True,
    },
    {
        "repo_id": "pyannote/wespeaker-voxceleb-resnet34-LM",
        "revision": "837717ddb9ff5507820346191109dc79c958d614",
        "directory": "pyannote-legacy/pyannote/wespeaker-voxceleb-resnet34-LM",
        "allow_patterns": None,
        "gated": True,
    },
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--skip-gated", action="store_true")
    parser.add_argument("--model", action="append", dest="selected_models")
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)
    token = os.environ.get("HF_TOKEN") or get_token()
    for model in MODELS:
        if args.selected_models and model["repo_id"] not in args.selected_models:
            continue
        if model["gated"] and args.skip_gated:
            print(f"skipping gated model {model['repo_id']} (--skip-gated)")
            continue
        target = args.root / str(model["directory"])
        print(f"downloading {model['repo_id']}@{model['revision']} to {target}")
        snapshot_download(
            repo_id=str(model["repo_id"]),
            revision=str(model["revision"]),
            local_dir=target,
            allow_patterns=model["allow_patterns"],
            token=token,
        )
        (target / ".contora-model-revision").write_text(
            str(model["revision"]) + "\n", encoding="utf-8"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
