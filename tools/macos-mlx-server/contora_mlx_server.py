#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import time
import uuid
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any

import torch
import uvicorn
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse, Response
from mlx_audio.stt.utils import load_model

from result_safety import (
    ResponseValidationError,
    atomic_write_json,
    sanitize_finite_numbers,
    strict_json_bytes,
    validate_transcription_response,
)


DEFAULT_MODEL = os.getenv(
    "CONTORA_MLX_MODEL",
    "mlx-community/whisper-large-v3-turbo-asr-fp16",
)
RUNTIME_ROOT = Path(
    os.getenv(
        "CONTORA_WHISPER_RUNTIME_ROOT",
        Path.home() / "Library/Application Support/NiketasAI/runtime/faster-whisper-xxl",
    )
).expanduser()
RESULTS_ROOT = Path(
    os.getenv(
        "CONTORA_MLX_RESULTS_ROOT",
        Path(__file__).resolve().parents[1] / "transcription-results",
    )
).expanduser()

app = FastAPI(title="Contora MLX transcription server")
_models: dict[str, Any] = {}
_diarization_pipeline = None


def timestamp(seconds: float | None) -> str:
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


def model_for(model_name: str):
    if model_name not in _models:
        _models[model_name] = load_model(model_name)
    return _models[model_name]


def local_pyannote_config() -> Path:
    config_path = RUNTIME_ROOT / "pyannote" / "speaker-diarization-3.1" / "config.yaml"
    if not config_path.exists():
        raise FileNotFoundError(f"pyannote config not found at {config_path}")

    local_config_path = RUNTIME_ROOT / "pyannote" / "speaker-diarization-3.1.local.yaml"
    config_text = config_path.read_text(encoding="utf-8")
    config_text = config_text.replace(
        "segmentation: pyannote/segmentation-3.0",
        "\n".join(
            [
                "segmentation:",
                f"      checkpoint: {RUNTIME_ROOT / 'pyannote' / 'segmentation-3.0' / 'pytorch_model.bin'}",
            ]
        ),
    )
    config_text = config_text.replace(
        "embedding: pyannote/wespeaker-voxceleb-resnet34-LM",
        "\n".join(
            [
                "embedding:",
                f"      checkpoint: {RUNTIME_ROOT / 'pyannote' / 'wespeaker-voxceleb-resnet34-LM' / 'pytorch_model.bin'}",
            ]
        ),
    )
    local_config_path.write_text(config_text, encoding="utf-8")
    return local_config_path


def diarization_pipeline():
    global _diarization_pipeline
    if _diarization_pipeline is not None:
        return _diarization_pipeline

    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(str(local_pyannote_config()))
    pipeline.to(torch.device("mps" if torch.backends.mps.is_available() else "cpu"))
    _diarization_pipeline = pipeline
    return pipeline


def normalize_stt_result(result: Any) -> dict[str, Any]:
    if isinstance(result, dict):
        normalized = dict(result)
    elif is_dataclass(result):
        normalized = asdict(result)
    else:
        normalized = {
            "text": getattr(result, "text", ""),
            "segments": getattr(result, "segments", []),
            "language": getattr(result, "language", None),
        }
    return sanitize_finite_numbers(normalized)


def normalize_segments(value: Any) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    for segment in list(value or []):
        if is_dataclass(segment):
            segment = asdict(segment)
        elif not isinstance(segment, dict):
            segment = vars(segment)
        segments.append(sanitize_finite_numbers(dict(segment)))
    return segments


def assign_speakers(audio_path: str, segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    diarization = diarization_pipeline()(audio_path)
    labelled: list[dict[str, Any]] = []

    for segment in segments:
        start = float(segment.get("start") or 0.0)
        end = float(segment.get("end") or start)
        best_speaker = "SPEAKER_00"
        best_overlap = 0.0

        for turn, _, speaker in diarization.itertracks(yield_label=True):
            overlap = max(0.0, min(end, float(turn.end)) - max(start, float(turn.start)))
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = str(speaker)

        labelled_segment = dict(segment)
        labelled_segment["speaker"] = best_speaker
        labelled.append(labelled_segment)
    return labelled


def formatted_text(segments: list[dict[str, Any]]) -> str:
    lines: list[str] = []
    for segment in segments:
        text = str(segment.get("text") or "").strip()
        if not text:
            continue
        speaker = str(segment.get("speaker") or "SPEAKER_00")
        lines.append(
            f"[{timestamp(segment.get('start'))} --> {timestamp(segment.get('end'))}] [{speaker}]: {text}"
        )
    return "\n".join(lines)


def failure_response(job_id: str, stage: str, exc: Exception, recoverable: bool) -> JSONResponse:
    error = {
        "schema_version": "1.0",
        "job_id": job_id,
        "state": "failed",
        "error": {
            "code": type(exc).__name__,
            "message": str(exc),
            "stage": stage,
            "recoverable": recoverable,
        },
    }
    try:
        atomic_write_json(RESULTS_ROOT / job_id / "failure.json", error)
    except OSError:
        # Preserve the original structured error even if diagnostic storage is unavailable.
        pass
    return JSONResponse(status_code=500, content=error)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "backend": "mlx+pyannote",
        "defaultModel": DEFAULT_MODEL,
        "torchMPS": torch.backends.mps.is_available(),
        "resultSafety": "finite-v1",
    }


@app.get("/v1/models")
def models():
    loaded = [{"id": name, "object": "model", "owned_by": "local"} for name in _models]
    if not any(item["id"] == DEFAULT_MODEL for item in loaded):
        loaded.insert(0, {"id": DEFAULT_MODEL, "object": "model", "owned_by": "local"})
    return {"object": "list", "data": loaded}


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form(DEFAULT_MODEL),
    language: str | None = Form(None),
    diarize: bool = Form(True),
    chunk_duration: float = Form(30.0),
):
    job_id = str(uuid.uuid4())
    job_root = RESULTS_ROOT / job_id
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    audio_path = job_root / f"input{suffix}"
    job_root.mkdir(parents=True, exist_ok=False)
    stage = "preparing"
    started = time.time()

    try:
        with audio_path.open("wb") as handle:
            shutil.copyfileobj(file.file, handle)

        stage = "transcribing"
        stt_model = model_for(model)
        generation_started = time.time()
        result_data = normalize_stt_result(
            stt_model.generate(
                str(audio_path),
                verbose=None,
                chunk_duration=chunk_duration,
                language=language or None,
            )
        )
        asr_seconds = time.time() - generation_started
        segments = normalize_segments(result_data.get("segments"))
        atomic_write_json(
            job_root / "asr.json",
            {
                "schema_version": "1.0",
                "job_id": job_id,
                "model": model,
                "language": result_data.get("language"),
                "text": str(result_data.get("text") or "").strip(),
                "segments": segments,
                "timing": {"asr": asr_seconds},
            },
        )

        diarization_seconds = 0.0
        if diarize:
            stage = "diarizing"
            diarization_started = time.time()
            segments = assign_speakers(str(audio_path), segments)
            diarization_seconds = time.time() - diarization_started
        else:
            for segment in segments:
                segment.setdefault("speaker", "SPEAKER_00")
        atomic_write_json(
            job_root / "diarization.json",
            {
                "schema_version": "1.0",
                "job_id": job_id,
                "enabled": diarize,
                "segments": segments,
                "timing": {"diarization": diarization_seconds},
            },
        )

        stage = "serializing"
        response_payload = sanitize_finite_numbers(
            {
                "schema_version": "1.0",
                "job_id": job_id,
                "text": formatted_text(segments) or str(result_data.get("text") or "").strip(),
                "raw_text": str(result_data.get("text") or "").strip(),
                "segments": segments,
                "language": result_data.get("language"),
                "backend": "mlx+pyannote" if diarize else "mlx",
                "model": model,
                "timing": {
                    "total": time.time() - started,
                    "asr": asr_seconds,
                    "diarization": diarization_seconds,
                },
            }
        )
        validate_transcription_response(response_payload)
        result_path = atomic_write_json(job_root / "result.json", response_payload)

        # Serve exactly the validated, persisted artifact. A later transport failure cannot erase it.
        return Response(content=result_path.read_bytes(), media_type="application/json")
    except ResponseValidationError as exc:
        return failure_response(job_id, stage, exc, recoverable=True)
    except Exception as exc:
        recoverable = (job_root / "asr.json").exists()
        return failure_response(job_id, stage, exc, recoverable=recoverable)


def main():
    host = os.getenv("CONTORA_MLX_HOST", "127.0.0.1")
    port = int(os.getenv("CONTORA_MLX_PORT", "8010"))
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
