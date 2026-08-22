#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path

from common import atomic_write, canonical_asr, require_model_revision


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--audio", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-path", type=Path)
    parser.add_argument("--model-revision", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--language", default="ru")
    args = parser.parse_args()
    if args.model_path:
        require_model_revision(args.model_path.parent, args.model_revision)

    report_root = args.output.parent / "argmax-report"
    report_root.mkdir(parents=True, exist_ok=True)
    command = [
        str(args.binary),
        "transcribe",
        "--audio-path",
        str(args.audio),
        "--language",
        args.language,
        "--word-timestamps",
        "--report",
        "--report-path",
        str(report_root),
    ]
    if args.model_path:
        command.extend(("--model-path", str(args.model_path)))
    else:
        command.extend(("--model", args.model))
    started = time.monotonic()
    subprocess.run(command, check=True)
    elapsed = time.monotonic() - started
    report_path = report_root / f"{args.audio.stem}.json"
    result = json.loads(report_path.read_text(encoding="utf-8"))
    payload = canonical_asr(
        result,
        engine={
            "id": "argmax-whisperkit",
            "version": args.version,
            "model": args.model,
            "model_revision": args.model_revision,
        },
        timing={
            "wrapper_total_seconds": elapsed,
            "upstream": result.get("timings"),
        },
    )
    atomic_write(args.output, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
