#!/usr/bin/env python3
import argparse
import json
import os
import sys
from pathlib import Path


PROGRESS_PREFIX = "CONTORA_PROGRESS "


def emit_progress(
    enabled: bool,
    phase: str,
    progress: float,
    message: str,
    current_seconds: float | None = None,
    total_seconds: float | None = None,
) -> None:
    if not enabled:
        return

    payload = {
        "phase": phase,
        "progress": max(0.0, min(1.0, float(progress))),
        "message": message,
    }
    if current_seconds is not None:
        payload["currentSeconds"] = max(0.0, float(current_seconds))
    if total_seconds is not None:
        payload["totalSeconds"] = max(0.0, float(total_seconds))
    print(PROGRESS_PREFIX + json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


def timestamp(seconds: float) -> str:
    seconds = max(0.0, float(seconds or 0.0))
    whole = int(seconds)
    millis = int(round((seconds - whole) * 1000))
    if millis >= 1000:
        whole += 1
        millis = 0
    hours = whole // 3600
    minutes = (whole % 3600) // 60
    secs = whole % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def speaker_for_segment(segment, diarization):
    if diarization is None:
        return "SPEAKER_00"

    best_speaker = "SPEAKER_00"
    best_overlap = 0.0
    start = float(segment.start)
    end = float(segment.end)
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        overlap = max(0.0, min(end, float(turn.end)) - max(start, float(turn.start)))
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = str(speaker)
    return best_speaker


def load_diarization(audio_path: str, enabled: bool):
    if not enabled:
        return None

    try:
        from pyannote.audio import Pipeline
    except Exception as exc:
        print(f"pyannote.audio is unavailable: {exc}; using one speaker.", file=sys.stderr)
        return None

    runtime_root = Path(
        os.environ.get("CONTORA_WHISPER_RUNTIME_ROOT", Path(__file__).resolve().parents[1])
    ).expanduser().resolve()
    candidates = [
        runtime_root / "pyannote" / "speaker-diarization-3.1",
        runtime_root / "models" / "pyannote" / "speaker-diarization-3.1",
    ]
    model_path = next((path for path in candidates if path.exists()), None)
    if model_path is None:
        print("Diarization requested but no bundled pyannote model was found; using one speaker.", file=sys.stderr)
        return None

    try:
        config_path = model_path / "config.yaml"
        local_config_path = runtime_root / "pyannote" / "speaker-diarization-3.1.local.yaml"
        config_text = config_path.read_text(encoding="utf-8")
        config_text = config_text.replace(
            "segmentation: pyannote/segmentation-3.0",
            "\n".join(
                [
                    "segmentation:",
                    f"      checkpoint: {runtime_root / 'pyannote' / 'segmentation-3.0' / 'pytorch_model.bin'}",
                ]
            ),
        )
        config_text = config_text.replace(
            "embedding: pyannote/wespeaker-voxceleb-resnet34-LM",
            "\n".join(
                [
                    "embedding:",
                    f"      checkpoint: {runtime_root / 'pyannote' / 'wespeaker-voxceleb-resnet34-LM' / 'pytorch_model.bin'}",
                ]
            ),
        )
        local_config_path.write_text(config_text, encoding="utf-8")
        pipeline = Pipeline.from_pretrained(str(local_config_path))
        return pipeline(audio_path)
    except Exception as exc:
        print(f"Bundled diarization unavailable: {exc}; using one speaker.", file=sys.stderr)
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("-pp", "--print_progress", action="store_true")
    parser.add_argument("-o", "--output_dir", default=".")
    parser.add_argument("--output_dir_alt", dest="output_dir_alt")
    parser.add_argument("--standard", action="store_true")
    parser.add_argument("-f", "--output_format", default="txt")
    parser.add_argument("--output_format_alt", dest="output_format_alt")
    parser.add_argument("-m", "--model", default="large-v2")
    parser.add_argument("--model_dir")
    parser.add_argument("--language", default=None)
    parser.add_argument("--task", default="transcribe")
    parser.add_argument("--diarize", nargs="?", const="pyannote_v3.1", default=None)
    parser.add_argument("audio")
    args = parser.parse_args()

    emit_progress(args.print_progress, "starting", 0.01, "Starting Local Whisper")

    try:
        from faster_whisper import WhisperModel
    except Exception as exc:
        print(f"faster-whisper is not installed: {exc}", file=sys.stderr)
        return 2

    model_size_or_path = args.model
    if args.model_dir:
        candidate = Path(args.model_dir) / f"faster-whisper-{args.model}"
        if candidate.exists():
            model_size_or_path = str(candidate)

    output_dir = Path(args.output_dir_alt or args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    audio_path = Path(args.audio)
    output_path = output_dir / f"{audio_path.stem}.txt"

    emit_progress(args.print_progress, "loading_model", 0.04, f"Loading Whisper model {args.model}")
    model = WhisperModel(model_size_or_path, device="auto", compute_type="auto")
    emit_progress(args.print_progress, "loading_audio", 0.10, "Loading and analyzing audio")
    segments_iter, info = model.transcribe(
        str(audio_path),
        language=args.language or None,
        task=args.task,
        vad_filter=True,
    )
    total_seconds = max(0.0, float(getattr(info, "duration", 0.0) or 0.0))
    segments = []
    last_reported_progress = 0.10
    emit_progress(
        args.print_progress,
        "transcribing",
        last_reported_progress,
        "Transcribing speech",
        current_seconds=0.0,
        total_seconds=total_seconds,
    )
    for segment in segments_iter:
        segments.append(segment)
        current_seconds = max(0.0, float(segment.end or 0.0))
        if total_seconds > 0:
            fraction = min(1.0, current_seconds / total_seconds)
            progress = min(0.82, 0.10 + (0.72 * fraction))
        else:
            progress = last_reported_progress
        if progress >= last_reported_progress + 0.005 or current_seconds >= total_seconds:
            last_reported_progress = progress
            emit_progress(
                args.print_progress,
                "transcribing",
                progress,
                "Transcribing speech",
                current_seconds=current_seconds,
                total_seconds=total_seconds,
            )

    emit_progress(
        args.print_progress,
        "transcribing",
        0.82,
        "Speech transcription complete",
        current_seconds=total_seconds,
        total_seconds=total_seconds,
    )

    if args.diarize is not None:
        emit_progress(args.print_progress, "diarizing", 0.84, "Identifying speakers")
    diarization = load_diarization(str(audio_path), args.diarize is not None)
    emit_progress(
        args.print_progress,
        "formatting",
        0.96,
        "Formatting transcript" if args.diarize is None else "Speaker identification complete",
    )

    with output_path.open("w", encoding="utf-8") as handle:
        for segment in segments:
            speaker = speaker_for_segment(segment, diarization)
            text = (segment.text or "").strip()
            if not text:
                continue
            handle.write(f"[{timestamp(segment.start)} --> {timestamp(segment.end)}] [{speaker}]: {text}\n")

    emit_progress(args.print_progress, "completed", 1.0, "Transcription complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
