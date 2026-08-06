#!/usr/bin/env python3
import json
import sys
import time
from pathlib import Path


def argument_value(name: str) -> str:
    index = sys.argv.index(name)
    return sys.argv[index + 1]


def main() -> int:
    output_dir = Path(argument_value("-o"))
    audio_path = Path(sys.argv[-1])
    output_dir.mkdir(parents=True, exist_ok=True)

    if argument_value("-m") == "cancel-test":
        print('CONTORA_PROGRESS {"phase":"test","progress":0.1,"message":"Waiting"}', flush=True)
        time.sleep(30)
        return 0

    # This exceeds the usual pipe buffer and reproduces the old wait-before-read deadlock.
    for index in range(12_000):
        print(f"diagnostic line {index}: simulated backend output", file=sys.stderr)

    for progress, message in ((0.1, "Loading audio"), (0.55, "Transcribing speech"), (1.0, "Transcription complete")):
        payload = {"phase": "test", "progress": progress, "message": message}
        print("CONTORA_PROGRESS " + json.dumps(payload, separators=(",", ":")), flush=True)

    (output_dir / f"{audio_path.stem}.txt").write_text("smoke-test transcript\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
