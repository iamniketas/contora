from __future__ import annotations

import argparse
import json
import threading
import time
from dataclasses import replace
from pathlib import Path
from typing import Any

from .pipeline import (
    PipelineConfig,
    PipelineProgress,
    assemble_utterances,
    attribute_speakers,
    consolidate_speaker_turns,
    diarize_local,
    formatted_utterances,
    normalize_asr_segments,
    recognition_quality,
)


def reprocess_job(job_root: Path, num_speakers: int, *, reuse_speaker_turns: bool = False) -> Path:
    diagnostics_path = job_root / "diagnostics.json"
    source_audio = job_root / "input.wav"
    original_result_path = job_root / "result.json"
    if not diagnostics_path.is_file() or not source_audio.is_file() or not original_result_path.is_file():
        raise FileNotFoundError("The saved job must contain diagnostics.json, input.wav, and result.json")

    diagnostics = json.loads(diagnostics_path.read_text(encoding="utf-8"))
    original = json.loads(original_result_path.read_text(encoding="utf-8"))
    response = diagnostics.get("response")
    if not isinstance(response, dict):
        raise ValueError("diagnostics.json has no saved Speech API response")

    config = replace(PipelineConfig.from_env(), num_speakers=num_speakers)
    total_seconds = None
    metadata = response.get("metadata") if isinstance(response.get("metadata"), dict) else {}
    try:
        total_seconds = int(metadata.get("totalDurationMs")) / 1000.0
    except (TypeError, ValueError):
        pass

    def progress(value: PipelineProgress) -> None:
        print(
            json.dumps(
                {
                    "phase": value.phase,
                    "progress": round(value.progress, 4),
                    "message": value.message,
                },
                ensure_ascii=False,
            ),
            flush=True,
        )

    started = time.time()
    if reuse_speaker_turns:
        saved_turns = original.get("speaker_turns")
        if not isinstance(saved_turns, list) or not saved_turns:
            raise ValueError("result.json has no saved speaker turns to reuse")
        turns = saved_turns
    else:
        turns = diarize_local(source_audio, config, threading.Event(), progress, total_seconds)
    turns = consolidate_speaker_turns(turns, num_speakers)
    words = attribute_speakers(normalize_asr_segments(response), turns)
    utterances = assemble_utterances(words)

    candidate: dict[str, Any] = dict(original)
    candidate.update(
        {
            "text": formatted_utterances(utterances) or str(response.get("transcript") or ""),
            "words": words,
            "speaker_turns": turns,
            "utterances": utterances,
            "segments": [
                {key: item[key] for key in ("start", "end", "speaker", "text")}
                for item in utterances
            ],
            "parameters": {"diarize": True, "num_speakers": num_speakers},
            "quality": recognition_quality(response, normalize_asr_segments(response)),
            "timing": {
                **(original.get("timing") if isinstance(original.get("timing"), dict) else {}),
                "reprocessing": time.time() - started,
            },
        }
    )
    suffix = "major" if reuse_speaker_turns else "spk"
    output_path = job_root / f"result.reprocessed-{num_speakers}{suffix}.json"
    temporary_path = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary_path.write_text(json.dumps(candidate, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary_path.replace(output_path)
    transcript_path = output_path.with_suffix(".txt")
    transcript_temporary = transcript_path.with_suffix(transcript_path.suffix + ".tmp")
    transcript_temporary.write_text(str(candidate["text"]), encoding="utf-8")
    transcript_temporary.replace(transcript_path)
    return output_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Re-run only local diarization and merge for a saved job")
    parser.add_argument("job_root", type=Path)
    parser.add_argument("--num-speakers", type=int, required=True, choices=range(1, 51))
    parser.add_argument(
        "--reuse-speaker-turns",
        action="store_true",
        help="Reuse automatic turns from result.json and only consolidate/merge them",
    )
    args = parser.parse_args()
    output = reprocess_job(
        args.job_root.expanduser(),
        args.num_speakers,
        reuse_speaker_turns=args.reuse_speaker_turns,
    )
    print(json.dumps({"state": "completed", "output": str(output)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
