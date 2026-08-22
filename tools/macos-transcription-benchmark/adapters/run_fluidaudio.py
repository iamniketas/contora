#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path

from common import atomic_write


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--mode", default="offline", choices=("offline", "streaming"))
    parser.add_argument("--threshold", type=float, default=0.7045655)
    parser.add_argument("--version", required=True)
    parser.add_argument("--model-revision", required=True)
    args = parser.parse_args()

    upstream_output = args.output.parent / "fluidaudio-result.json"
    started = time.monotonic()
    subprocess.run(
        [
            str(args.binary),
            "process",
            str(args.audio),
            "--mode",
            args.mode,
            "--threshold",
            str(args.threshold),
            "--output",
            str(upstream_output),
        ],
        check=True,
    )
    elapsed = time.monotonic() - started
    upstream = json.loads(upstream_output.read_text(encoding="utf-8"))
    turns = [
        {
            "start": float(item["startTimeSeconds"]),
            "end": float(item["endTimeSeconds"]),
            "speaker": str(item["speakerId"]),
            "confidence": item.get("qualityScore"),
        }
        for item in upstream.get("segments", [])
    ]
    atomic_write(
        args.output,
        {
            "schema_version": "1.0",
            "kind": "diarization",
            "engine": {
                "id": "fluidaudio",
                "version": args.version,
                "model": "speaker-diarization-coreml",
                "model_revision": args.model_revision,
                "mode": args.mode,
                "threshold": args.threshold,
            },
            "text": "",
            "segments": [],
            "words": [],
            "speaker_turns": turns,
            "timing": {
                "wrapper_total_seconds": elapsed,
                "upstream_processing_seconds": upstream.get("processingTimeSeconds"),
                "upstream": upstream.get("timings"),
            },
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
