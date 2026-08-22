#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import json
import os
import re
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
from pydantic import BaseModel, Field

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
HANDOFF_ROOT = Path(
    os.getenv(
        "CONTORA_MLX_HANDOFF_ROOT",
        Path.home() / "Library/Application Support/Contora/TranscriptionHandoff",
    )
).expanduser()
JOB_TTL_SECONDS = max(60.0, float(os.getenv("CONTORA_MLX_JOB_TTL_SECONDS", str(7 * 24 * 60 * 60))))
TERMINAL_JOB_TTL_SECONDS = max(
    JOB_TTL_SECONDS,
    float(os.getenv("CONTORA_MLX_TERMINAL_JOB_TTL_SECONDS", str(30 * 24 * 60 * 60))),
)
CAPABILITY_TOKEN_PATTERN = re.compile(r"^[a-f0-9]{32,64}$")

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


class FileHandoffRequest(BaseModel):
    capability_token: str = Field(min_length=32, max_length=64)
    model: str = DEFAULT_MODEL
    language: str | None = None
    diarize: bool = True
    chunk_duration: float = Field(default=30.0, gt=0.0, le=120.0)


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


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _path_within(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
        return True
    except (FileNotFoundError, OSError, ValueError):
        return False


def _resolve_handoff(token: str) -> tuple[Path, Path]:
    normalized_token = token.lower()
    if not CAPABILITY_TOKEN_PATTERN.fullmatch(normalized_token):
        raise ValueError("Invalid audio capability token")

    descriptor_path = HANDOFF_ROOT / f"{normalized_token}.json"
    descriptor = _read_json(descriptor_path)
    if descriptor is None:
        raise FileNotFoundError("Audio capability is missing or invalid")
    if descriptor.get("capability_token") != normalized_token:
        raise ValueError("Audio capability token does not match its descriptor")

    audio_path_value = descriptor.get("audio_path")
    if not isinstance(audio_path_value, str) or not audio_path_value:
        raise ValueError("Audio capability does not contain a valid audio path")
    audio_path = Path(audio_path_value).expanduser()
    expected_audio_path = HANDOFF_ROOT / f"{normalized_token}.wav"
    if audio_path.resolve(strict=True) != expected_audio_path.resolve(strict=True):
        raise ValueError("Audio capability is not bound to its canonical artifact")
    if not _path_within(descriptor_path, HANDOFF_ROOT) or not _path_within(audio_path, HANDOFF_ROOT):
        raise ValueError("Audio capability points outside the Contora handoff directory")
    if not audio_path.is_file() or audio_path.is_symlink():
        raise ValueError("Audio capability must point to a regular non-symlink file")
    return descriptor_path, audio_path.resolve(strict=True)


def _job_snapshot(job_id: str) -> dict[str, Any] | None:
    with _jobs_lock:
        status = _jobs.get(job_id)
        if status is not None:
            return dict(status)
    status = _read_json(RESULTS_ROOT / job_id / "status.json")
    if status is not None and status.get("job_id") == job_id:
        with _jobs_lock:
            _jobs[job_id] = status
        return dict(status)
    return None


def _store_job_status(job_id: str, **changes: Any) -> dict[str, Any]:
    with _jobs_lock:
        status = _jobs.get(job_id)
        if status is None:
            status = _read_json(RESULTS_ROOT / job_id / "status.json")
        if status is None:
            raise KeyError(f"Unknown transcription job {job_id}")
        previous_progress = float(status.get("progress") or 0.0)
        if "progress" in changes:
            changes["progress"] = min(1.0, max(previous_progress, float(changes["progress"])))
        status.update(sanitize_finite_numbers(changes))
        status["updated_at"] = time.time()
        snapshot = dict(status)
    atomic_write_json(RESULTS_ROOT / job_id / "status.json", snapshot)
    return snapshot


def _job_manifest(job_id: str) -> dict[str, Any] | None:
    manifest = _read_json(RESULTS_ROOT / job_id / "job.json")
    if manifest is None or manifest.get("job_id") != job_id:
        return None
    return manifest


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


def _write_job_manifest(
    job_id: str,
    audio_path: Path,
    *,
    model: str,
    language: str | None,
    diarize: bool,
    chunk_duration: float,
    capability_token: str | None = None,
    capability_descriptor: Path | None = None,
) -> dict[str, Any]:
    manifest = {
        "schema_version": "1.0",
        "job_id": job_id,
        "audio_path": str(audio_path.resolve(strict=True)),
        "model": model,
        "language": language,
        "diarize": diarize,
        "chunk_duration": chunk_duration,
        "capability_token": capability_token,
        "capability_descriptor": str(capability_descriptor.resolve(strict=True)) if capability_descriptor else None,
        "created_at": time.time(),
    }
    atomic_write_json(RESULTS_ROOT / job_id / "job.json", manifest)
    return manifest


def _prepare_uploaded_job(
    file: UploadFile,
    *,
    model: str,
    language: str | None,
    diarize: bool,
    chunk_duration: float,
) -> tuple[str, Path]:
    job_id = str(uuid.uuid4())
    job_root = RESULTS_ROOT / job_id
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    audio_path = job_root / f"input{suffix}"
    job_root.mkdir(parents=True, exist_ok=False)
    with audio_path.open("wb") as handle:
        shutil.copyfileobj(file.file, handle)
    _write_job_manifest(
        job_id,
        audio_path,
        model=model,
        language=language,
        diarize=diarize,
        chunk_duration=chunk_duration,
    )
    _initialize_job(job_id, audio_duration_seconds(audio_path), diarize=diarize)
    with _jobs_lock:
        _job_cancellations[job_id] = threading.Event()
    return job_id, audio_path


def _prepare_handoff_job(request: FileHandoffRequest) -> tuple[str, Path]:
    descriptor_path, audio_path = _resolve_handoff(request.capability_token)
    job_id = str(uuid.uuid4())
    job_root = RESULTS_ROOT / job_id
    job_root.mkdir(parents=True, exist_ok=False)
    claimed_descriptor = job_root / "capability.json"
    try:
        os.replace(descriptor_path, claimed_descriptor)
        _write_job_manifest(
            job_id,
            audio_path,
            model=request.model,
            language=request.language,
            diarize=request.diarize,
            chunk_duration=request.chunk_duration,
            capability_token=request.capability_token.lower(),
            capability_descriptor=claimed_descriptor,
        )
        _initialize_job(job_id, audio_duration_seconds(audio_path), diarize=request.diarize)
    except Exception:
        if claimed_descriptor.exists() and not descriptor_path.exists():
            try:
                os.replace(claimed_descriptor, descriptor_path)
            except OSError:
                pass
        shutil.rmtree(job_root, ignore_errors=True)
        raise
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
            try:
                (job_root / "failure.json").unlink(missing_ok=True)
            except OSError:
                pass
            _raise_if_cancelled(cancel_event)
            stage = "transcribing"
            total_seconds = (_job_snapshot(job_id) or {}).get("total_seconds")
            asr_end = 0.45 if diarize else 0.95

            asr_checkpoint = _read_json(job_root / "asr.json")
            if asr_checkpoint is not None and asr_checkpoint.get("model") == model:
                result_data = asr_checkpoint
                segments = normalize_segments(asr_checkpoint.get("segments"))
                asr_seconds = float((asr_checkpoint.get("timing") or {}).get("asr") or 0.0)
                _update_progress(
                    job_id,
                    started=started,
                    state="transcribing",
                    phase="transcribing",
                    message="Resumed from ASR checkpoint",
                    progress=asr_end,
                    processed_seconds=float(total_seconds or 0.0),
                    asr_progress=1.0,
                )
            else:
                _update_progress(
                    job_id,
                    started=started,
                    state="loading_models",
                    phase="loading_models",
                    message="Loading MLX model",
                    progress=0.01,
                )
                stt_model = model_for(model)
                generation_started = time.time()

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
            diarization_checkpoint = _read_json(job_root / "diarization.json")
            if diarization_checkpoint is not None and bool(diarization_checkpoint.get("enabled")) == diarize:
                segments = normalize_segments(diarization_checkpoint.get("segments"))
                diarization_seconds = float(
                    (diarization_checkpoint.get("timing") or {}).get("diarization") or 0.0
                )
                _update_progress(
                    job_id,
                    started=started,
                    state="diarizing" if diarize else "transcribing",
                    phase="diarizing" if diarize else "transcribing",
                    message="Resumed from diarization checkpoint",
                    progress=0.97 if diarize else 0.95,
                    processed_seconds=float(total_seconds or 0.0),
                    diarization_progress=1.0,
                )
            elif diarize:
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


def _manifest_audio_path(job_id: str, manifest: dict[str, Any]) -> Path | None:
    value = manifest.get("audio_path")
    if not isinstance(value, str) or not value:
        return None
    audio_path = Path(value).expanduser()
    job_root = RESULTS_ROOT / job_id
    token = manifest.get("capability_token")
    if isinstance(token, str) and CAPABILITY_TOKEN_PATTERN.fullmatch(token):
        expected = HANDOFF_ROOT / f"{token}.wav"
        try:
            if (
                not audio_path.is_symlink()
                and audio_path.resolve(strict=True) == expected.resolve(strict=True)
                and _path_within(audio_path, HANDOFF_ROOT)
            ):
                return audio_path.resolve(strict=True)
        except OSError:
            return None
    elif _path_within(audio_path, job_root) and not audio_path.is_symlink():
        return audio_path.resolve(strict=True)
    return None


def _delete_handoff_artifacts(manifest: dict[str, Any]) -> None:
    token = manifest.get("capability_token")
    if not isinstance(token, str) or not CAPABILITY_TOKEN_PATTERN.fullmatch(token):
        return
    for candidate in (HANDOFF_ROOT / f"{token}.json", HANDOFF_ROOT / f"{token}.wav"):
        if _path_within(candidate, HANDOFF_ROOT):
            try:
                candidate.unlink(missing_ok=True)
            except OSError:
                pass


def _cleanup_expired_jobs(now: float | None = None) -> list[str]:
    current_time = time.time() if now is None else now
    removed: list[str] = []
    try:
        job_roots = list(RESULTS_ROOT.iterdir())
    except OSError:
        return removed

    for job_root in job_roots:
        if not job_root.is_dir():
            continue
        status = _read_json(job_root / "status.json")
        if status is None:
            continue
        state = status.get("state")
        delivered_at = status.get("result_delivered_at")
        updated_at = status.get("updated_at")
        expired = (
            state == "completed"
            and isinstance(delivered_at, (int, float))
            and current_time - float(delivered_at) >= JOB_TTL_SECONDS
        ) or (
            state in {"failed", "cancelled"}
            and isinstance(updated_at, (int, float))
            and current_time - float(updated_at) >= TERMINAL_JOB_TTL_SECONDS
        )
        if not expired:
            continue

        job_id = str(status.get("job_id") or job_root.name)
        manifest = _read_json(job_root / "job.json") or {}
        _delete_handoff_artifacts(manifest)
        try:
            shutil.rmtree(job_root)
        except OSError:
            continue
        with _jobs_lock:
            _jobs.pop(job_id, None)
            _job_cancellations.pop(job_id, None)
            _job_tasks.pop(job_id, None)
        removed.append(job_id)
    return removed


def _recover_persisted_jobs() -> list[str]:
    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    HANDOFF_ROOT.mkdir(parents=True, exist_ok=True)
    _cleanup_expired_jobs()
    resumed: list[str] = []

    for job_root in sorted(RESULTS_ROOT.iterdir()):
        if not job_root.is_dir():
            continue
        status = _read_json(job_root / "status.json")
        if status is None:
            continue
        job_id = status.get("job_id")
        if not isinstance(job_id, str) or job_id != job_root.name:
            continue
        with _jobs_lock:
            _jobs[job_id] = status

        if (job_root / "result.json").is_file():
            if status.get("state") != "completed":
                _store_job_status(
                    job_id,
                    state="completed",
                    phase="completed",
                    message="Recovered completed result",
                    progress=1.0,
                    eta_seconds=0.0,
                    error=None,
                )
            continue
        if status.get("state") in {"completed", "failed", "cancelled"}:
            continue
        if status.get("state") == "cancelling":
            _store_job_status(
                job_id,
                state="cancelled",
                phase="cancelled",
                message="Cancelled during backend restart",
                eta_seconds=None,
                error=None,
            )
            continue

        manifest = _job_manifest(job_id)
        audio_path = _manifest_audio_path(job_id, manifest) if manifest is not None else None
        if manifest is None or audio_path is None:
            exc = RuntimeError("Cannot resume job: persisted audio manifest is missing or unsafe")
            error = failure_payload(job_id, "recovering", exc, recoverable=False)
            _store_job_status(
                job_id,
                state="failed",
                phase="recovering",
                message=str(exc),
                eta_seconds=None,
                error=error["error"],
            )
            continue

        with _jobs_lock:
            _job_cancellations[job_id] = threading.Event()
        _store_job_status(
            job_id,
            state="queued",
            phase="queued",
            message="Resuming after backend restart",
            eta_seconds=None,
            error=None,
        )
        _start_background_job(
            job_id,
            audio_path,
            model=str(manifest.get("model") or DEFAULT_MODEL),
            language=manifest.get("language") if isinstance(manifest.get("language"), str) else None,
            diarize=bool(manifest.get("diarize", True)),
            chunk_duration=float(manifest.get("chunk_duration") or 30.0),
        )
        resumed.append(job_id)
    return resumed


@app.on_event("startup")
async def recover_persisted_jobs_on_startup():
    _recover_persisted_jobs()


@app.post("/v1/transcription/jobs")
async def create_transcription_job(
    file: UploadFile = File(...),
    model: str = Form(DEFAULT_MODEL),
    language: str | None = Form(None),
    diarize: bool = Form(True),
    chunk_duration: float = Form(30.0),
):
    _cleanup_expired_jobs()
    job_id, audio_path = _prepare_uploaded_job(
        file,
        model=model,
        language=language,
        diarize=diarize,
        chunk_duration=chunk_duration,
    )
    _start_background_job(
        job_id,
        audio_path,
        model=model,
        language=language,
        diarize=diarize,
        chunk_duration=chunk_duration,
    )
    return JSONResponse(status_code=202, content=_job_snapshot(job_id))


@app.post("/v1/transcription/jobs/from-file")
async def create_transcription_job_from_file(request: FileHandoffRequest):
    _cleanup_expired_jobs()
    try:
        job_id, audio_path = _prepare_handoff_job(request)
    except (FileNotFoundError, OSError, ValueError) as exc:
        return JSONResponse(status_code=400, content={"detail": str(exc)})
    _start_background_job(
        job_id,
        audio_path,
        model=request.model,
        language=request.language,
        diarize=request.diarize,
        chunk_duration=request.chunk_duration,
    )
    return JSONResponse(status_code=202, content=_job_snapshot(job_id))


@app.get("/v1/transcription/jobs/{job_id}")
def transcription_job_status(job_id: str):
    _cleanup_expired_jobs()
    status = _job_snapshot(job_id)
    if status is None:
        return JSONResponse(status_code=404, content={"detail": "Job not found"})
    return JSONResponse(content=status)


@app.get("/v1/transcription/jobs/{job_id}/result")
def transcription_job_result(job_id: str):
    _cleanup_expired_jobs()
    job_root = RESULTS_ROOT / job_id
    result_path = job_root / "result.json"
    if result_path.exists():
        result_bytes = result_path.read_bytes()
        _store_job_status(job_id, result_delivered_at=time.time())
        return Response(content=result_bytes, media_type="application/json")
    failure_path = job_root / "failure.json"
    if failure_path.exists():
        return Response(content=failure_path.read_bytes(), status_code=500, media_type="application/json")
    status = _job_snapshot(job_id)
    if status is None:
        return JSONResponse(status_code=404, content={"detail": "Job not found"})
    return JSONResponse(status_code=409, content=status)


@app.delete("/v1/transcription/jobs/{job_id}")
def cancel_transcription_job(job_id: str):
    _cleanup_expired_jobs()
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
    _cleanup_expired_jobs()
    job_id, audio_path = _prepare_uploaded_job(
        file,
        model=model,
        language=language,
        diarize=diarize,
        chunk_duration=chunk_duration,
    )
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
        result_bytes = result_path.read_bytes()
        _store_job_status(job_id, result_delivered_at=time.time())
        return Response(content=result_bytes, media_type="application/json")
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
