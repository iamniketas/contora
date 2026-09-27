from __future__ import annotations

import json
import os
import re
import shutil
import threading
import time
import uuid
from dataclasses import replace
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from .pipeline import (
    PipelineCancelled,
    PipelineConfig,
    PipelineError,
    PipelineProgress,
    audio_duration_seconds,
    run_pipeline,
)


HOST = os.getenv("CONTORA_VK_HOST", "127.0.0.1")
PORT = int(os.getenv("CONTORA_VK_PORT", "8020"))
HANDOFF_ROOT = Path(
    os.getenv(
        "CONTORA_MLX_HANDOFF_ROOT",
        Path.home() / "Library/Application Support/Contora/TranscriptionHandoff",
    )
).expanduser()
RESULTS_ROOT = Path(
    os.getenv(
        "CONTORA_VK_RESULTS_ROOT",
        Path.home() / "Library/Application Support/ContoraCorporate/VKTranscriptionJobs",
    )
).expanduser()
TOKEN_PATTERN = re.compile(r"^[a-f0-9]{32,64}$")


class FileHandoffRequest(BaseModel):
    capability_token: str = Field(min_length=32, max_length=64)
    model: str = "latest"
    language: str | None = None
    diarize: bool = True
    chunk_duration: float = Field(default=30.0, gt=0.0, le=120.0)
    num_speakers: int | None = Field(default=None, ge=1, le=50)


app = FastAPI(title="Contora Corporate ASR sidecar")
_lock = threading.Lock()
_jobs: dict[str, dict[str, Any]] = {}
_cancellations: dict[str, threading.Event] = {}


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def _status_path(job_id: str) -> Path:
    return RESULTS_ROOT / job_id / "status.json"


def _result_path(job_id: str) -> Path:
    return RESULTS_ROOT / job_id / "result.json"


def _store_status(job_id: str, **updates: Any) -> dict[str, Any]:
    with _lock:
        current = dict(_jobs.get(job_id) or {"job_id": job_id})
        if "progress" in updates and isinstance(current.get("progress"), (int, float)):
            updates["progress"] = max(float(current["progress"]), float(updates["progress"]))
        current.update(updates)
        _jobs[job_id] = current
        _atomic_json(_status_path(job_id), current)
        return dict(current)


def _load_status(job_id: str) -> dict[str, Any] | None:
    with _lock:
        if job_id in _jobs:
            return dict(_jobs[job_id])
    try:
        value = json.loads(_status_path(job_id).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _resolve_handoff(token: str) -> tuple[Path, Path]:
    normalized = token.lower()
    if not TOKEN_PATTERN.fullmatch(normalized):
        raise ValueError("Invalid capability token")
    descriptor_path = HANDOFF_ROOT / f"{normalized}.json"
    try:
        descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise FileNotFoundError("Audio capability is missing or invalid") from exc
    if descriptor.get("capability_token") != normalized:
        raise ValueError("Capability token does not match descriptor")
    audio_path = Path(str(descriptor.get("audio_path") or ""))
    expected = HANDOFF_ROOT / f"{normalized}.wav"
    if audio_path.is_symlink() or audio_path.resolve(strict=True) != expected.resolve(strict=True):
        raise ValueError("Capability is not bound to its canonical audio artifact")
    return descriptor_path, audio_path


def _prepare_job(request: FileHandoffRequest) -> tuple[str, Path]:
    descriptor, audio = _resolve_handoff(request.capability_token)
    job_id = str(uuid.uuid4())
    job_root = RESULTS_ROOT / job_id
    job_root.mkdir(parents=True, exist_ok=False)
    destination = job_root / "input.wav"
    shutil.copy2(audio, destination)
    descriptor.unlink(missing_ok=True)
    audio.unlink(missing_ok=True)
    _store_status(
        job_id,
        state="queued",
        phase="queued",
        message="Queued",
        progress=0.0,
        processed_seconds=0.0,
        total_seconds=audio_duration_seconds(destination),
        elapsed_seconds=0.0,
        eta_seconds=None,
        error=None,
    )
    return job_id, destination


def _run_job(job_id: str, audio_path: Path, diarize: bool, num_speakers: int | None) -> None:
    cancel = _cancellations[job_id]
    started = time.time()
    branch_lock = threading.Lock()
    branch_progress = {"asr": 0.0, "diarization": 0.0 if diarize else 1.0}

    def on_progress(value: PipelineProgress) -> None:
        reported_progress = min(1.0, max(0.0, value.progress))
        message = value.message
        processed_seconds = value.processed_seconds
        extra: dict[str, Any] = {}
        if value.phase in {"transcribing", "diarizing"}:
            branch = "asr" if value.phase == "transcribing" else "diarization"
            with branch_lock:
                branch_progress[branch] = max(branch_progress[branch], reported_progress)
                asr_progress = branch_progress["asr"]
                diarization_progress = branch_progress["diarization"]
            reported_progress = 0.10 + 0.85 * (
                (0.15 * asr_progress) + (0.85 * diarization_progress)
            )
            message = (
                f"Parallel · VK ASR {asr_progress:.0%} · "
                f"diarization {diarization_progress:.0%} · {value.message}"
            )
            if value.total_seconds is not None:
                processed_seconds = value.total_seconds * reported_progress
            extra = {
                "asr_progress": asr_progress,
                "diarization_progress": diarization_progress,
            }
        _store_status(
            job_id,
            state="running",
            phase=value.phase,
            message=message,
            progress=reported_progress,
            processed_seconds=processed_seconds,
            total_seconds=value.total_seconds,
            elapsed_seconds=max(0.0, time.time() - started),
            eta_seconds=None,
            error=None,
            **extra,
        )

    try:
        config = (
            replace(PipelineConfig.from_env(), num_speakers=num_speakers)
            if num_speakers is not None
            else None
        )
        result = run_pipeline(
            audio_path,
            job_id,
            RESULTS_ROOT,
            enable_diarization=diarize,
            cancel=cancel,
            progress=on_progress,
            config=config,
        )
        _atomic_json(_result_path(job_id), result)
        _store_status(
            job_id,
            state="completed",
            phase="completed",
            message="Completed",
            progress=1.0,
            processed_seconds=None,
            elapsed_seconds=max(0.0, time.time() - started),
            eta_seconds=0.0,
            error=None,
        )
    except PipelineCancelled:
        _store_status(
            job_id,
            state="cancelled",
            phase="cancelled",
            message="Cancelled",
            eta_seconds=None,
            error=None,
        )
    except Exception as exc:
        failure = {
            "code": type(exc).__name__,
            "message": str(exc),
            "stage": (_load_status(job_id) or {}).get("phase", "unknown"),
            "recoverable": (RESULTS_ROOT / job_id / "diagnostics.json").exists(),
        }
        _store_status(
            job_id,
            state="failed",
            phase=failure["stage"],
            message=failure["message"],
            eta_seconds=None,
            error=failure,
        )


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "backend": "corporate-asr+local-diarization"}


@app.get("/ready")
def ready() -> Any:
    try:
        config = PipelineConfig.from_env()
    except PipelineError as exc:
        return JSONResponse(
            status_code=503,
            content={"status": "not_ready", "message": str(exc)},
        )
    return {
        "status": "ready",
        "backend": "corporate-asr+local-diarization",
        "model": config.speech_model,
        "tokenConfigured": True,
    }


@app.get("/v1/models")
def models() -> dict[str, Any]:
    return {"object": "list", "data": [{"id": "latest", "object": "model", "owned_by": "corporate"}]}


@app.post("/v1/transcription/jobs/from-file", status_code=202)
def create_job(request: FileHandoffRequest) -> Any:
    try:
        job_id, audio_path = _prepare_job(request)
    except (FileNotFoundError, OSError, ValueError) as exc:
        return JSONResponse(status_code=400, content={"error": {"message": str(exc)}})
    cancel = threading.Event()
    with _lock:
        _cancellations[job_id] = cancel
    threading.Thread(
        target=_run_job,
        args=(job_id, audio_path, request.diarize, request.num_speakers),
        name=f"contora-vk-{job_id[:8]}",
        daemon=True,
    ).start()
    return _load_status(job_id) or {"job_id": job_id, "state": "queued"}


@app.get("/v1/transcription/jobs/{job_id}")
def get_job(job_id: str) -> Any:
    status = _load_status(job_id)
    return status if status is not None else JSONResponse(status_code=404, content={"error": "Job not found"})


@app.get("/v1/transcription/jobs/{job_id}/result")
def get_result(job_id: str) -> JSONResponse:
    status = _load_status(job_id)
    if status is None:
        return JSONResponse(status_code=404, content={"error": "Job not found"})
    if status.get("state") != "completed":
        return JSONResponse(status_code=409, content={"job_id": job_id, "error": status.get("error")})
    try:
        payload = json.loads(_result_path(job_id).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return JSONResponse(status_code=500, content={"error": "Persisted result is unavailable"})
    return JSONResponse(content=payload)


@app.delete("/v1/transcription/jobs/{job_id}")
def cancel_job(job_id: str) -> Any:
    with _lock:
        cancellation = _cancellations.get(job_id)
    if cancellation is None:
        return JSONResponse(status_code=404, content={"error": "Job not found"})
    cancellation.set()
    return {"job_id": job_id, "state": "cancelling"}


def main() -> None:
    if HOST not in {"127.0.0.1", "localhost", "::1"} and os.getenv("CONTORA_VK_ALLOW_REMOTE") != "1":
        raise RuntimeError("Refusing non-loopback bind without CONTORA_VK_ALLOW_REMOTE=1")
    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    HANDOFF_ROOT.mkdir(parents=True, exist_ok=True)
    uvicorn.run(app, host=HOST, port=PORT)


if __name__ == "__main__":
    main()
