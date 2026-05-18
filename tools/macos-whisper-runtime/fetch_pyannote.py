#!/usr/bin/env python3
import argparse
import os
from pathlib import Path

from huggingface_hub import snapshot_download


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--token", default=os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN"))
    parser.add_argument("--token-file")
    args = parser.parse_args()

    if args.token_file:
        args.token = Path(args.token_file).read_text(encoding="utf-8").strip()

    if not args.token:
        raise SystemExit("HF_TOKEN, HUGGINGFACE_TOKEN, or --token-file is required on the build machine.")

    output = Path(args.output)
    pyannote_root = output / "pyannote"
    pyannote_root.mkdir(parents=True, exist_ok=True)

    snapshot_download(
        repo_id="pyannote/speaker-diarization-3.1",
        local_dir=pyannote_root / "speaker-diarization-3.1",
        local_dir_use_symlinks=False,
        token=args.token,
    )

    snapshot_download(
        repo_id="pyannote/segmentation-3.0",
        local_dir=pyannote_root / "segmentation-3.0",
        local_dir_use_symlinks=False,
        token=args.token,
    )

    snapshot_download(
        repo_id="pyannote/wespeaker-voxceleb-resnet34-LM",
        local_dir=pyannote_root / "wespeaker-voxceleb-resnet34-LM",
        local_dir_use_symlinks=False,
        token=args.token,
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
