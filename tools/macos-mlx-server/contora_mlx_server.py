#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import json
import os
import shutil
import threading
import time
import uuid
import wave
from contextlib import contextmanager
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any, Callable

import torch
import uvicorn
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse, Response
from mlx_audio.stt.utils import load_model

from result_safety import (
    ResponseValidationError,
    atomic_write_json,
    sanitize_finite_numbers,
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
_jobs: dict[str, dict[str, Any]] = {}
_job_tasks: dict[str, asyncio.Task] = {}
_job_cancellations: dict[str, threading.Event] = {}
_jobs_lock = threading.Lock()
_processing_lock = threading.Lock()


class JobCancelledError(Exception):
    pass


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


def audio_duration_seconds(audio_path: Path) -> float | None:
    try:
        with wave.open(str(audio_path), "rb") as handle:
            frame_rate = handle.getframerate()
            return handle.getnframes() / frame_rate if frame_rate > 0 else None
    except (OSError, EOFError, wave.Error):
        return None


def _job_snapshot(job_id: str) -> dict[str, Any] | None:
    with _jobs_lock:
        status = _jobs.get(job_id)
        return dict(status) if status is not None else None


def _store_job_status(job_id: str, **changes: Any) -> dict[str, Any]:
    with _jobs_lock:
        status = _jobs[job_id]
        previous_progress = float(status.get("progress") or 0.0)
        if "progress" in changes:
            changes["progress"] = min(1.0, max(previous_progress, float(changes["progress"])))
        status.update(sanitize_finite_numbers(changes))
        status["updated_at"] = time.time()
        snapshot = dict(status)
    atomic_write_json(RESULTS_ROOT / job_id / "status.json", snapshot)
    return snapshot


def _initialize_job(job_id: str, total_seconds: float | None, *, diarize: bool) -> dict[str, Any]:
    now = time.time()
    status = {
        "schema_version": "1.0",
        "job_id": job_id,
        "state": "queued",
        "phase": "queued",
        "message": "Queued",
        "progress": 0.0,
        "asr_progress": 0.0,
        "diarization_progress": 0.0 if diarize else 1.0,
        "processed_seconds": 0.0,
        "total_seconds": total_seconds,
        "elapsed_seconds": 0.0,
        "eta_seconds": None,
        "created_at": now,
        "updated_at": now,
        "error": None,
    }
    with _jobs_lock:
        _jobs[job_id] = status
    atomic_write_json(RESULTS_ROOT / job_id / "status.json", status)
    return dict(status)


def _estimated_remaining(started: float, progress: float) -> float | None:
    elapsed = max(0.0, time.time() - started)
    if progress < 0.03 or elapsed < 1.0:
        return None
    return max(0.0, elapsed * (1.0 - progress) / progress)


def _update_progress(
    job_id: str,
    *,
    started: float,
    state: str,
    phase: str,
    message: str,
    progress: float,
    processed_seconds: float | None = None,
    asr_progress: float | None = None,
    diarization_progress: float | None = None,
) -> None:
    changes: dict[str, Any] = {
        "state": state,
        "phase": phase,
        "message": message,
        "progress": progress,
        "elapsed_seconds": max(0.0, time.time() - started),
        "eta_seconds": _estimated_remaining(started, progress),
    }
    if processed_seconds is not None:
        changes["processed_seconds"] = processed_seconds
    if asr_progress is not None:
        changes["asr_progress"] = asr_progress
    if diarization_progress is not None:
        changes["diarization_progress"] = diarization_progress
    _store_job_status(job_id, **changes)


def _raise_if_cancelled(cancel_event: threading.Event) -> None:
    if cancel_event.is_set():
        raise JobCancelledError("Transcription cancelled")


@contextmanager
def mlx_progress_callback(callback: Callable[[float], None]):
    """Observe Whisper's internal seek loop without splitting audio into external chunks."""
    from mlx_audio.stt.models.whisper import whisper as whisper_module

    original_tqdm = whisper_module.tqdm.tqdm

    class CallbackProgressBar:
        def __init__(self, *args, **kwargs):
            self._inner = original_tqdm(*args, **kwargs)
            self.total = float(kwargs.get("total") or getattr(self._inner, "total", 0.0) or 0.0)
            self.completed = 0.0

        def __enter__(self):
            self._inner.__enter__()
            callback(0.0)
            return self

        def __exit__(self, *args):
            return self._inner.__exit__(*args)

        def update(self, amount=1):
            self.completed = min(self.total, self.completed + float(amount or 0.0))
            result = self._inner.update(amount)
            if self.total > 0:
                callback(self.completed / self.total)
            return result

        def __getattr__(self, name):
            return getattr(self._inner, name)

    whisper_module.tqdm.tqdm = CallbackProgressBar
    try:
        yield
    finally:
        whisper_module.tqdm.tqdm = original_tqdm


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


def assign_speakers(
    audio_path: str,
    segments: list[dict[str, Any]],
    progress_callback: Callable[[float, str], None] | None = None,
) -> list[dict[str, Any]]:
    step_ranges = {
        "segmentation": (0.0, 0.30),
        "speaker_counting": (0.30, 0.35),
        "embeddings": (0.35, 0.95),
        "discrete_diarization": (0.95, 1.0),
    }
    observed_progress = 0.0

    def hook(step_name, _artifact, file=None, total=None, completed=None):
        nonlocal observed_progress
        start, end = step_ranges.get(str(step_name), (observed_progress, min(1.0, observed_progress + 0.02)))
        if total and completed is not None:
            fraction = min(1.0, max(0.0, float(completed) / float(total)))
            candidate = start + ((end - start) * fraction)
        else:
            candidate = end
        observed_progress = max(observed_progress, candidate)
        if progress_callback is not None:
            progress_callback(observed_progress, str(step_name))

    diarization = diarization_pipeline()(audio_path, hook=hook if progress_callback is not None else None)
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


def failure_payload(job_id: str, stage: str, exc: Exception, recoverable: bool) -> dict[str, Any]:
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
    return error


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


def _prepare_job(file: UploadFile, *, diarize: bool) -> tuple[str, Path]:
    job_id = str(uuid.uuid4())
    job_root = RESULTS_ROOT / job_id
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    audio_path = job_root / f"input{suffix}"
    job_root.mkdir(parents=True, exist_ok=False)
    with audio_path.open("wb") as handle:
        shutil.copyfileobj(file.file, handle)
    _initialize_job(job_id, audio_duration_seconds(audio_path), diarize=diarize)
    with _jobs_lock:
        _job_cancellations[job_id] = threading.Event()
    return job_id, audio_path


def _run_transcription_job(
    job_id: str,
    audio_path: Path,
    *,
    model: str,
    language: str | None,
    diarize: bool,
    chunk_duration: float,
) -> None:
    job_root = RESULTS_ROOT / job_id
    with _jobs_lock:
        cancel_event = _job_cancellations[job_id]
    stage = "queued"

    try:
        with _processing_lock:
            started = time.time()
            _raise_if_cancelled(cancel_event)
            _update_progress(
                job_id,
                started=started,
                state="loading_models",
                phase="loading_models",
                message="Loading MLX model",
                progress=0.01,
            )

            stage = "transcribing"
            stt_model = model_for(model)
            generation_started = time.time()
            total_seconds = (_job_snapshot(job_id) or {}).get("total_seconds")
            asr_end = 0.45 if diarize else 0.95

            def on_asr_progress(fraction: float) -> None:
                _raise_if_cancelled(cancel_event)
                fraction = min(1.0, max(0.0, fraction))
                processed = float(total_seconds or 0.0) * fraction
                _update_progress(
                    job_id,
                    started=started,
                    state="transcribing",
                    phase="transcribing",
                    message=f"Transcribing audio · {int(fraction * 100)}%",
                    progress=0.05 + ((asr_end - 0.05) * fraction),
                    processed_seconds=processed,
                    asr_progress=fraction,
                )

            on_asr_progress(0.0)
            with mlx_progress_callback(on_asr_progress):
                result_data = normalize_stt_result(
                    stt_model.generate(
                        str(audio_path),
                        verbose=None,
                        chunk_duration=chunk_duration,
                        language=language or None,
                    )
                )
            on_asr_progress(1.0)
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

                def on_diarization_progress(fraction: float, step_name: str) -> None:
                    _raise_if_cancelled(cancel_event)
                    fraction = min(1.0, max(0.0, fraction))
                    processed = float(total_seconds or 0.0) * fraction
                    readable_step = step_name.replace("_", " ").capitalize()
                    _update_progress(
                        job_id,
                        started=started,
                        state="diarizing",
                        phase="diarizing",
                        message=f"Detecting speakers · {readable_step}",
                        progress=0.45 + (0.52 * fraction),
                        processed_seconds=processed,
                        diarization_progress=fraction,
                    )

                on_diarization_progress(0.0, "segmentation")
                segments = assign_speakers(
                    str(audio_path),
                    segments,
                    progress_callback=on_diarization_progress,
                )
                on_diarization_progress(1.0, "complete")
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

            _raise_if_cancelled(cancel_event)
            stage = "serializing"
            _update_progress(
                job_id,
                started=started,
                state="merging",
                phase="merging",
                message="Merging and validating result",
                progress=0.98,
                processed_seconds=float(total_seconds or 0.0),
            )
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
            atomic_write_json(job_root / "result.json", response_payload)
            _store_job_status(
                job_id,
                state="completed",
                phase="completed",
                message="Completed",
                progress=1.0,
                asr_progress=1.0,
                diarization_progress=1.0,
                processed_seconds=float(total_seconds or 0.0),
                elapsed_seconds=max(0.0, time.time() - started),
                eta_seconds=0.0,
                error=None,
            )
    except JobCancelledError:
        snapshot = _job_snapshot(job_id) or {}
        _store_job_status(
            job_id,
            state="cancelled",
            phase="cancelled",
            message="Cancelled",
            progress=float(snapshot.get("progress") or 0.0),
            eta_seconds=None,
            error=None,
        )
    except ResponseValidationError as exc:
        error = failure_payload(job_id, stage, exc, recoverable=True)
        _store_job_status(
            job_id,
            state="failed",
            phase=stage,
            message=str(exc),
            eta_seconds=None,
            error=error["error"],
        )
    except Exception as exc:
        recoverable = (job_root / "asr.json").exists()
        error = failure_payload(job_id, stage, exc, recoverable=recoverable)
        _store_job_status(
            job_id,
            state="failed",
            phase=stage,
            message=str(exc),
            eta_seconds=None,
            error=error["error"],
        )


def _start_background_job(job_id: str, audio_path: Path, **parameters: Any) -> None:
    async def runner():
        try:
            await asyncio.to_thread(_run_transcription_job, job_id, audio_path, **parameters)
        finally:
            with _jobs_lock:
                _job_tasks.pop(job_id, None)

    task = asyncio.create_task(runner())
    with _jobs_lock:
        _job_tasks[job_id] = task


@app.post("/v1/transcription/jobs")
async def create_transcription_job(
    file: UploadFile = File(...),
    model: str = Form(DEFAULT_MODEL),
    language: str | None = Form(None),
    diarize: bool = Form(True),
    chunk_duration: float = Form(30.0),
):
    job_id, audio_path = _prepare_job(file, diarize=diarize)
    _start_background_job(
        job_id,
        audio_path,
        model=model,
        language=language,
        diarize=diarize,
        chunk_duration=chunk_duration,
    )
    return JSONResponse(status_code=202, content=_job_snapshot(job_id))


@app.get("/v1/transcription/jobs/{job_id}")
def transcription_job_status(job_id: str):
    status = _job_snapshot(job_id)
    if status is None:
        status_path = RESULTS_ROOT / job_id / "status.json"
        if status_path.exists():
            status = json.loads(status_path.read_text(encoding="utf-8"))
    if status is None:
        return JSONResponse(status_code=404, content={"detail": "Job not found"})
    return JSONResponse(content=status)


@app.get("/v1/transcription/jobs/{job_id}/result")
def transcription_job_result(job_id: str):
    job_root = RESULTS_ROOT / job_id
    result_path = job_root / "result.json"
    if result_path.exists():
        return Response(content=result_path.read_bytes(), media_type="application/json")
    failure_path = job_root / "failure.json"
    if failure_path.exists():
        return Response(content=failure_path.read_bytes(), status_code=500, media_type="application/json")
    status = _job_snapshot(job_id)
    if status is None:
        return JSONResponse(status_code=404, content={"detail": "Job not found"})
    return JSONResponse(status_code=409, content=status)


@app.delete("/v1/transcription/jobs/{job_id}")
def cancel_transcription_job(job_id: str):
    with _jobs_lock:
        cancel_event = _job_cancellations.get(job_id)
    if cancel_event is None:
        return JSONResponse(status_code=404, content={"detail": "Job not found"})
    cancel_event.set()
    status = _job_snapshot(job_id) or {}
    if status.get("state") not in {"completed", "failed", "cancelled"}:
        status = _store_job_status(
            job_id,
            state="cancelling",
            phase="cancelling",
            message="Cancelling",
            eta_seconds=None,
        )
    return JSONResponse(status_code=202, content=status)


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model: str = Form(DEFAULT_MODEL),
    language: str | None = Form(None),
    diarize: bool = Form(True),
    chunk_duration: float = Form(30.0),
):
    """Compatibility endpoint for older Contora clients."""
    job_id, audio_path = _prepare_job(file, diarize=diarize)
    await asyncio.to_thread(
        _run_transcription_job,
        job_id,
        audio_path,
        model=model,
        language=language,
        diarize=diarize,
        chunk_duration=chunk_duration,
    )
    result_path = RESULTS_ROOT / job_id / "result.json"
    if result_path.exists():
        return Response(content=result_path.read_bytes(), media_type="application/json")
    failure_path = RESULTS_ROOT / job_id / "failure.json"
    if failure_path.exists():
        return Response(content=failure_path.read_bytes(), status_code=500, media_type="application/json")
    status = _job_snapshot(job_id) or {"detail": "Transcription did not complete"}
    return JSONResponse(status_code=409, content=status)


def main():
    host = os.getenv("CONTORA_MLX_HOST", "127.0.0.1")
    port = int(os.getenv("CONTORA_MLX_PORT", "8010"))
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
