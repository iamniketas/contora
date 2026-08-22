#!/usr/bin/env python3
from __future__ import annotations

import asyncio
from collections import deque
from concurrent.futures import Future, ThreadPoolExecutor
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
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
HARDWARE_PROFILE_PATH = Path(
    os.getenv("CONTORA_MLX_HARDWARE_PROFILE_PATH", RESULTS_ROOT.parent / "hardware-profiles.json")
).expanduser()
CAPABILITY_TOKEN_PATTERN = re.compile(r"^[a-f0-9]{32,64}$")
FLUID_MODEL_REVISION = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
FLUID_BINARY = Path(
    os.getenv("CONTORA_MLX_FLUID_BINARY", RESULTS_ROOT.parent / "bin/contora-fluid-diarize")
).expanduser()
FLUID_MODELS_ROOT = Path(
    os.getenv("CONTORA_MLX_FLUID_MODELS_ROOT", RESULTS_ROOT.parent / "models")
).expanduser()

app = FastAPI(title="Contora MLX transcription server")
_models: dict[str, Any] = {}
_diarization_pipeline = None
_jobs: dict[str, dict[str, Any]] = {}
_job_tasks: dict[str, asyncio.Task] = {}
_job_cancellations: dict[str, threading.Event] = {}
_job_telemetry: dict[str, dict[str, Any]] = {}
_jobs_lock = threading.Lock()
_processing_lock = threading.Lock()


class JobCancelledError(Exception):
    pass


class ParallelDiarizationAborted(Exception):
    pass


class FileHandoffRequest(BaseModel):
    capability_token: str = Field(min_length=32, max_length=64)
    model: str = DEFAULT_MODEL
    language: str | None = None
    diarize: bool = True
    chunk_duration: float = Field(default=30.0, gt=0.0, le=120.0)


class RollingRateEstimator:
    def __init__(self, *, minimum_samples: int = 3, minimum_span: float = 1.0):
        self.minimum_samples = minimum_samples
        self.minimum_span = minimum_span
        self.samples: deque[tuple[float, float]] = deque(maxlen=12)
        self.smoothed_rate: float | None = None

    def observe(self, processed_seconds: float, *, now: float | None = None) -> dict[str, float | None]:
        observed_at = time.monotonic() if now is None else now
        processed = max(0.0, float(processed_seconds))
        if self.samples and processed <= self.samples[-1][1]:
            return self.metrics()
        self.samples.append((observed_at, processed))
        if len(self.samples) >= self.minimum_samples and self.samples[-1][0] - self.samples[0][0] >= self.minimum_span:
            rates = []
            for previous, current in zip(self.samples, list(self.samples)[1:]):
                wall_delta = current[0] - previous[0]
                audio_delta = current[1] - previous[1]
                if wall_delta > 0 and audio_delta > 0:
                    rates.append(audio_delta / wall_delta)
            if rates:
                robust_rate = statistics.median(rates[-7:])
                self.smoothed_rate = (
                    robust_rate
                    if self.smoothed_rate is None
                    else (0.3 * robust_rate) + (0.7 * self.smoothed_rate)
                )
        return self.metrics()

    def metrics(self) -> dict[str, float | None]:
        processed = self.samples[-1][1] if self.samples else 0.0
        return {"processed": processed, "rate": self.smoothed_rate}


def _command_output(arguments: list[str]) -> str:
    try:
        completed = subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return f"{completed.stdout}\n{completed.stderr}".strip()


def apple_silicon_resource_snapshot() -> dict[str, Any]:
    memory_output = _command_output(["/usr/bin/memory_pressure", "-Q"])
    memory_match = re.search(r"System-wide memory free percentage:\s*(\d+)%", memory_output)
    free_percent = float(memory_match.group(1)) if memory_match else None
    swap_output = _command_output(["/usr/sbin/sysctl", "-n", "vm.swapusage"])
    swap_match = re.search(r"used\s*=\s*([0-9.]+)([MGT])", swap_output)
    multiplier = {"M": 1024**2, "G": 1024**3, "T": 1024**4}
    swap_used = (
        float(swap_match.group(1)) * multiplier[swap_match.group(2)] if swap_match else None
    )
    thermal_output = _command_output(["/usr/bin/pmset", "-g", "therm"])
    thermal_warning = any(
        marker in thermal_output.lower()
        for marker in ("warning level = 1", "warning level = 2", "warning level = 3")
    )
    thermal_limits = [
        int(value)
        for value in re.findall(r"(?:CPU_Scheduler_Limit|CPU_Speed_Limit)\s*=\s*(\d+)", thermal_output)
    ]
    thermal_warning = thermal_warning or any(value < 100 for value in thermal_limits)
    return {
        "memory_free_percent": free_percent,
        "swap_used_bytes": swap_used,
        "thermal_warning": thermal_warning,
    }


def parallel_ane_decision(
    *,
    diarize: bool,
    snapshot: dict[str, Any] | None = None,
) -> tuple[bool, str]:
    if not diarize:
        return False, "diarization-disabled"
    if os.getenv("CONTORA_MLX_ENABLE_EXPERIMENTAL_ANE") != "1":
        return False, "ane-quality-gate-disabled"
    if os.getenv("CONTORA_MLX_ENABLE_PARALLEL_ANE") != "1":
        return False, "parallel-feature-disabled"
    if not FLUID_BINARY.is_file() or not os.access(FLUID_BINARY, os.X_OK):
        return False, "fluid-binary-unavailable"
    model_marker = FLUID_MODELS_ROOT / "speaker-diarization-coreml/.contora-model-revision"
    try:
        revision = model_marker.read_text(encoding="utf-8").strip()
    except OSError:
        return False, "fluid-models-unavailable"
    if revision != FLUID_MODEL_REVISION:
        return False, "fluid-model-revision-mismatch"

    resources = apple_silicon_resource_snapshot() if snapshot is None else snapshot
    free_percent = resources.get("memory_free_percent")
    swap_used = resources.get("swap_used_bytes")
    if resources.get("thermal_warning"):
        return False, "thermal-warning"
    if isinstance(free_percent, (int, float)) and float(free_percent) < 20.0:
        return False, "memory-pressure"
    if isinstance(swap_used, (int, float)) and float(swap_used) > 4 * 1024**3:
        return False, "swap-pressure"
    return True, "ane-quality-gate-enabled"


def run_fluid_diarization(
    audio_path: Path,
    output_path: Path,
    *,
    cancel_event: threading.Event,
    abort_event: threading.Event,
) -> list[dict[str, Any]]:
    command = [
        str(FLUID_BINARY),
        "--audio",
        str(audio_path),
        "--output",
        str(output_path),
        "--models",
        str(FLUID_MODELS_ROOT),
        "--model-revision",
        FLUID_MODEL_REVISION,
        "--threshold",
        os.getenv("CONTORA_MLX_FLUID_THRESHOLD", "0.7045655"),
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    last_guard_check = 0.0
    guard_ok = True
    guard_reason = "cancelled"
    while process.poll() is None:
        check_time = time.monotonic()
        if check_time - last_guard_check >= 2.0:
            last_guard_check = check_time
            guard_ok, guard_reason = parallel_ane_decision(
                diarize=True,
                snapshot=apple_silicon_resource_snapshot(),
            )
            if not guard_ok:
                abort_event.set()
        if cancel_event.is_set() or abort_event.is_set():
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            reason = guard_reason if not guard_ok else "cancelled"
            raise ParallelDiarizationAborted(reason)
        time.sleep(0.25)
    if process.returncode != 0:
        raise RuntimeError(f"FluidAudio exited with {process.returncode}")
    payload = _read_json(output_path)
    if payload is None or not isinstance(payload.get("speaker_turns"), list):
        raise RuntimeError("FluidAudio did not publish valid speaker turns")
    engine = payload.get("engine") or {}
    if engine.get("modelRevision", engine.get("model_revision")) != FLUID_MODEL_REVISION:
        raise RuntimeError("FluidAudio result model revision does not match the pinned revision")
    return normalize_segments(payload["speaker_turns"])


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


def _hardware_profile_key(model: str, diarize: bool, execution_mode: str = "sequential") -> str:
    hardware = os.getenv("CONTORA_MLX_HARDWARE_PROFILE", platform.machine())
    return f"{hardware}|{model}|{'diarize' if diarize else 'asr-only'}|{execution_mode}"


def _load_hardware_profile(
    model: str,
    diarize: bool,
    execution_mode: str = "sequential",
) -> dict[str, Any] | None:
    payload = _read_json(HARDWARE_PROFILE_PATH)
    if payload is None:
        return None
    profiles = payload.get("profiles")
    if not isinstance(profiles, dict):
        return None
    profile = profiles.get(_hardware_profile_key(model, diarize, execution_mode))
    return profile if isinstance(profile, dict) else None


def _store_hardware_profile(
    model: str,
    diarize: bool,
    *,
    asr_seconds: float,
    diarization_seconds: float,
    merge_seconds: float,
    audio_seconds: float,
    execution_mode: str = "sequential",
) -> None:
    payload = _read_json(HARDWARE_PROFILE_PATH) or {"schema_version": "1.0", "profiles": {}}
    profiles = payload.setdefault("profiles", {})
    key = _hardware_profile_key(model, diarize, execution_mode)
    previous = profiles.get(key) if isinstance(profiles.get(key), dict) else {}
    sample_count = int(previous.get("sample_count") or 0)
    alpha = 1.0 if sample_count == 0 else 0.25

    def smoothed(field: str, current: float) -> float:
        old = float(previous.get(field) or current)
        return (alpha * max(0.0, current)) + ((1.0 - alpha) * old)

    duration = max(0.001, audio_seconds)
    profiles[key] = {
        "sample_count": sample_count + 1,
        "asr_wall_per_audio": smoothed("asr_wall_per_audio", asr_seconds / duration),
        "diarization_wall_per_audio": smoothed(
            "diarization_wall_per_audio", diarization_seconds / duration
        ),
        "merge_wall_per_audio": smoothed("merge_wall_per_audio", merge_seconds / duration),
        "updated_at": time.time(),
    }
    HARDWARE_PROFILE_PATH.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_json(HARDWARE_PROFILE_PATH, payload)


def _stage_weights(
    model: str,
    diarize: bool,
    execution_mode: str = "sequential",
) -> tuple[float, float, float]:
    profile = _load_hardware_profile(model, diarize, execution_mode)
    if profile is None:
        return (0.90, 0.0, 0.05) if not diarize else (0.40, 0.52, 0.03)
    try:
        asr = max(0.001, float(profile.get("asr_wall_per_audio") or 0.0))
        diarization = (
            max(0.0, float(profile.get("diarization_wall_per_audio") or 0.0))
            if diarize
            else 0.0
        )
        merge = max(0.001, float(profile.get("merge_wall_per_audio") or 0.0))
    except (TypeError, ValueError):
        return (0.90, 0.0, 0.05) if not diarize else (0.40, 0.52, 0.03)
    scale = 0.95 / (asr + diarization + merge)
    return asr * scale, diarization * scale, merge * scale


def _telemetry_for(job_id: str) -> dict[str, Any]:
    with _jobs_lock:
        return _job_telemetry.setdefault(
            job_id,
            {"asr": RollingRateEstimator(), "diarization": RollingRateEstimator()},
        )


def _profile_rate(profile: dict[str, Any] | None, field: str) -> float:
    try:
        return max(0.0, float((profile or {}).get(field) or 0.0))
    except (TypeError, ValueError):
        return 0.0


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
        "asr_eta_seconds": None,
        "diarization_eta_seconds": None,
        "asr_elapsed_seconds": 0.0,
        "diarization_elapsed_seconds": 0.0,
        "effective_rtf": None,
        "created_at": now,
        "updated_at": now,
        "error": None,
    }
    with _jobs_lock:
        _jobs[job_id] = status
    atomic_write_json(RESULTS_ROOT / job_id / "status.json", status)
    return dict(status)


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
    eta_seconds: float | None = None,
    effective_rtf: float | None = None,
    asr_eta_seconds: float | None = None,
    diarization_eta_seconds: float | None = None,
    asr_elapsed_seconds: float | None = None,
    diarization_elapsed_seconds: float | None = None,
) -> None:
    changes: dict[str, Any] = {
        "state": state,
        "phase": phase,
        "message": message,
        "progress": progress,
        "elapsed_seconds": max(0.0, time.time() - started),
        "eta_seconds": eta_seconds,
    }
    if processed_seconds is not None:
        changes["processed_seconds"] = processed_seconds
    if asr_progress is not None:
        changes["asr_progress"] = asr_progress
    if diarization_progress is not None:
        changes["diarization_progress"] = diarization_progress
    if effective_rtf is not None:
        changes["effective_rtf"] = effective_rtf
    if asr_eta_seconds is not None:
        changes["asr_eta_seconds"] = asr_eta_seconds
    if diarization_eta_seconds is not None:
        changes["diarization_eta_seconds"] = diarization_eta_seconds
    if asr_elapsed_seconds is not None:
        changes["asr_elapsed_seconds"] = asr_elapsed_seconds
    if diarization_elapsed_seconds is not None:
        changes["diarization_elapsed_seconds"] = diarization_elapsed_seconds
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
    turns = diarize_speaker_turns(audio_path, progress_callback=progress_callback)
    labelled: list[dict[str, Any]] = []
    for segment in segments:
        start = float(segment.get("start") or 0.0)
        end = float(segment.get("end") or start)
        scores = _speaker_overlap_scores(start, end, turns)
        labelled_segment = dict(segment)
        labelled_segment["speaker"] = max(scores, key=scores.get) if scores else "SPEAKER_00"
        labelled.append(labelled_segment)
    return labelled


def diarize_speaker_turns(
    audio_path: str,
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
    turns = [
        {
            "start": float(turn.start),
            "end": float(turn.end),
            "speaker": str(speaker),
            "confidence": None,
        }
        for turn, _, speaker in diarization.itertracks(yield_label=True)
        if float(turn.end) >= float(turn.start)
    ]
    return sorted(turns, key=lambda turn: (turn["start"], turn["end"], turn["speaker"]))


def extract_asr_words(segments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    words: list[dict[str, Any]] = []
    for segment_index, segment in enumerate(segments):
        for item in list(segment.get("words") or []):
            if not isinstance(item, dict):
                continue
            text = item.get("word", item.get("text"))
            start = item.get("start")
            end = item.get("end")
            if not isinstance(text, str) or not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
                continue
            start_value = max(0.0, float(start))
            end_value = max(start_value, float(end))
            words.append(
                {
                    "text": text,
                    "start": start_value,
                    "end": end_value,
                    "confidence": item.get("probability", item.get("confidence")),
                    "asr_segment_index": segment_index,
                }
            )
    return words


def _speaker_overlap_scores(
    start: float,
    end: float,
    turns: list[dict[str, Any]],
) -> dict[str, float]:
    scores: dict[str, float] = {}
    for turn in turns:
        overlap = max(
            0.0,
            min(end, float(turn.get("end") or 0.0)) - max(start, float(turn.get("start") or 0.0)),
        )
        if overlap > 0:
            speaker = str(turn.get("speaker") or "SPEAKER_00")
            scores[speaker] = scores.get(speaker, 0.0) + overlap
    return scores


def _concurrent_speakers(start: float, end: float, turns: list[dict[str, Any]]) -> list[str]:
    active = [
        turn
        for turn in turns
        if min(end, float(turn.get("end") or 0.0)) > max(start, float(turn.get("start") or 0.0))
    ]
    speakers: set[str] = set()
    for index, first in enumerate(active):
        for second in active[index + 1 :]:
            if first.get("speaker") == second.get("speaker"):
                continue
            simultaneous = min(
                end,
                float(first.get("end") or 0.0),
                float(second.get("end") or 0.0),
            ) - max(
                start,
                float(first.get("start") or 0.0),
                float(second.get("start") or 0.0),
            )
            if simultaneous > 0:
                speakers.add(str(first.get("speaker") or "SPEAKER_00"))
                speakers.add(str(second.get("speaker") or "SPEAKER_00"))
    return sorted(speakers)


def attribute_speakers_to_words(
    words: list[dict[str, Any]],
    turns: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    attributed: list[dict[str, Any]] = []
    previous_speaker: str | None = None
    for word in words:
        start = float(word.get("start") or 0.0)
        end = max(start, float(word.get("end") or start))
        duration = max(0.001, end - start)
        midpoint = start + ((end - start) / 2.0)
        overlaps = _speaker_overlap_scores(start, end, turns)
        ranked = sorted(overlaps.items(), key=lambda item: (-item[1], item[0]))

        if len(ranked) >= 2:
            top_score = ranked[0][1]
            close_speakers = {
                speaker_name
                for speaker_name, score in ranked
                if top_score > 0 and score / top_score >= 0.9
            }
            midpoint_speakers = {
                str(turn.get("speaker") or "SPEAKER_00")
                for turn in turns
                if float(turn.get("start") or 0.0) <= midpoint <= float(turn.get("end") or 0.0)
            }
            midpoint_match = sorted(close_speakers & midpoint_speakers)
            if len(midpoint_match) == 1:
                chosen = midpoint_match[0]
                ranked.sort(key=lambda item: (item[0] != chosen, -item[1], item[0]))
            elif previous_speaker in close_speakers:
                ranked.sort(key=lambda item: (item[0] != previous_speaker, -item[1], item[0]))

        if ranked:
            speaker, raw_score = ranked[0]
        else:
            midpoint_turn = next(
                (
                    turn
                    for turn in turns
                    if float(turn.get("start") or 0.0) <= midpoint <= float(turn.get("end") or 0.0)
                ),
                None,
            )
            if midpoint_turn is not None:
                speaker = str(midpoint_turn.get("speaker") or "SPEAKER_00")
                raw_score = duration * 0.5
            elif turns:
                nearest = min(
                    turns,
                    key=lambda turn: min(
                        abs(midpoint - float(turn.get("start") or 0.0)),
                        abs(midpoint - float(turn.get("end") or 0.0)),
                    ),
                )
                nearest_distance = min(
                    abs(midpoint - float(nearest.get("start") or 0.0)),
                    abs(midpoint - float(nearest.get("end") or 0.0)),
                )
                if nearest_distance <= 0.5:
                    speaker = str(nearest.get("speaker") or "SPEAKER_00")
                    raw_score = duration * max(0.0, 0.5 - nearest_distance)
                else:
                    speaker = previous_speaker or "SPEAKER_00"
                    raw_score = 0.0
            else:
                speaker = previous_speaker or "SPEAKER_00"
                raw_score = duration

        overlap_speakers = _concurrent_speakers(start, end, turns)
        labelled = dict(word)
        labelled["speaker"] = speaker
        labelled["speaker_score"] = min(1.0, max(0.0, raw_score / duration))
        labelled["overlap"] = len(overlap_speakers) > 1
        labelled["overlap_speakers"] = overlap_speakers
        attributed.append(sanitize_finite_numbers(labelled))
        previous_speaker = speaker
    return attributed


def _join_word_text(parts: list[str]) -> str:
    result = ""
    punctuation = set(",.!?:;)]}»”")
    for part in parts:
        if not part:
            continue
        if not result or part[0].isspace() or part[0] in punctuation:
            result += part
        else:
            result += " " + part
    return result.strip()


def assemble_utterances(
    words: list[dict[str, Any]],
    *,
    max_gap_seconds: float = 1.5,
    max_characters: int = 240,
) -> list[dict[str, Any]]:
    utterances: list[dict[str, Any]] = []
    current_words: list[dict[str, Any]] = []

    def flush() -> None:
        if not current_words:
            return
        utterances.append(
            {
                "start": float(current_words[0]["start"]),
                "end": float(current_words[-1]["end"]),
                "speaker": str(current_words[0].get("speaker") or "SPEAKER_00"),
                "text": _join_word_text([str(word.get("text") or "") for word in current_words]),
                "word_start_index": len(words_seen) - len(current_words),
                "word_end_index": len(words_seen),
                "overlap": any(bool(word.get("overlap")) for word in current_words),
            }
        )
        current_words.clear()

    words_seen: list[dict[str, Any]] = []
    for word in words:
        candidate_text = _join_word_text(
            [str(item.get("text") or "") for item in current_words] + [str(word.get("text") or "")]
        )
        gap = (
            float(word.get("start") or 0.0) - float(current_words[-1].get("end") or 0.0)
            if current_words
            else 0.0
        )
        should_split = bool(
            current_words
            and (
                word.get("speaker") != current_words[-1].get("speaker")
                or bool(word.get("overlap")) != bool(current_words[-1].get("overlap"))
                or gap > max_gap_seconds
                or len(candidate_text) > max_characters
            )
        )
        if should_split:
            flush()
        current_words.append(word)
        words_seen.append(word)
    flush()
    return utterances


def formatted_utterances(utterances: list[dict[str, Any]]) -> str:
    return "\n".join(
        f"[{timestamp(item.get('start'))} --> {timestamp(item.get('end'))}] "
        f"[{item.get('speaker') or 'SPEAKER_00'}]: {str(item.get('text') or '').strip()}"
        for item in utterances
        if str(item.get("text") or "").strip()
    )


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
        "parallelANE": {
            "qualityGateEnabled": os.getenv("CONTORA_MLX_ENABLE_EXPERIMENTAL_ANE") == "1",
            "rolloutEnabled": os.getenv("CONTORA_MLX_ENABLE_PARALLEL_ANE") == "1",
            "adapterAvailable": FLUID_BINARY.is_file() and os.access(FLUID_BINARY, os.X_OK),
            "modelRevision": FLUID_MODEL_REVISION,
        },
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
    fluid_executor: ThreadPoolExecutor | None = None
    fluid_future: Future[list[dict[str, Any]]] | None = None
    fluid_abort_event = threading.Event()
    execution_mode = "sequential_pyannote" if diarize else "asr_only"
    scheduler_reason = "pyannote-fallback" if diarize else "diarization-disabled"
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
            total_value = float(total_seconds or 0.0)
            telemetry = _telemetry_for(job_id)
            diarization_checkpoint = _read_json(job_root / "diarization.json")
            reusable_diarization_checkpoint = bool(
                diarization_checkpoint is not None
                and diarization_checkpoint.get("schema_version") == "2.0"
                and bool(diarization_checkpoint.get("enabled")) == diarize
                and isinstance(diarization_checkpoint.get("speaker_turns"), list)
            )
            parallel_enabled, scheduler_reason = parallel_ane_decision(diarize=diarize)
            if parallel_enabled and not reusable_diarization_checkpoint:
                execution_mode = "parallel_ane"
                fluid_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="contora-fluid")
                fluid_future = fluid_executor.submit(
                    run_fluid_diarization,
                    audio_path,
                    job_root / "fluid-diarization.json",
                    cancel_event=cancel_event,
                    abort_event=fluid_abort_event,
                )
            elif reusable_diarization_checkpoint:
                execution_mode = "checkpoint"
                scheduler_reason = "diarization-checkpoint-reused"
            profile_mode = "parallel_ane" if execution_mode == "parallel_ane" else "sequential"
            profile = _load_hardware_profile(model, diarize, profile_mode)
            asr_weight, diarization_weight, merge_weight = _stage_weights(
                model, diarize, profile_mode
            )
            asr_start = 0.05
            asr_end = asr_start + asr_weight
            diarization_end = asr_end + diarization_weight
            _store_job_status(
                job_id,
                execution_mode=execution_mode,
                diarization_engine="fluidaudio" if execution_mode == "parallel_ane" else "pyannote",
                scheduler_reason=scheduler_reason,
            )

            asr_checkpoint = _read_json(job_root / "asr.json")
            checkpoint_words = (
                extract_asr_words(normalize_segments(asr_checkpoint.get("segments")))
                if asr_checkpoint is not None
                else []
            )
            checkpoint_has_words = bool(checkpoint_words) or not str(
                (asr_checkpoint or {}).get("text") or ""
            ).strip()
            if (
                asr_checkpoint is not None
                and asr_checkpoint.get("model") == model
                and asr_checkpoint.get("word_timestamps") is True
                and checkpoint_has_words
            ):
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
                    processed_seconds=total_value,
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
                last_guard_check = 0.0

                def on_asr_progress(fraction: float) -> None:
                    nonlocal last_guard_check, scheduler_reason
                    _raise_if_cancelled(cancel_event)
                    fraction = min(1.0, max(0.0, fraction))
                    processed = total_value * fraction
                    rate = telemetry["asr"].observe(processed).get("rate")
                    asr_eta = (total_value - processed) / rate if rate and total_value > processed else None
                    if fluid_future is not None and not fluid_future.done():
                        check_time = time.monotonic()
                        if check_time - last_guard_check >= 2.0:
                            last_guard_check = check_time
                            guard_ok, guard_reason = parallel_ane_decision(
                                diarize=diarize,
                                snapshot=apple_silicon_resource_snapshot(),
                            )
                            if not guard_ok:
                                scheduler_reason = guard_reason
                                fluid_abort_event.set()
                                _store_job_status(job_id, scheduler_reason=guard_reason)
                    remaining = asr_eta
                    if remaining is not None:
                        if diarize:
                            profiled_diarization = _profile_rate(
                                profile, "diarization_wall_per_audio"
                            )
                            diarization_remaining = (
                                total_value * profiled_diarization
                                if profiled_diarization > 0
                                else (total_value / rate) * (diarization_weight / max(asr_weight, 0.001))
                            )
                            remaining = (
                                max(remaining, diarization_remaining)
                                if execution_mode == "parallel_ane"
                                else remaining + diarization_remaining
                            )
                        profiled_merge = _profile_rate(profile, "merge_wall_per_audio")
                        remaining += (
                            total_value * profiled_merge
                            if profiled_merge > 0
                            else (total_value / rate) * (merge_weight / max(asr_weight, 0.001))
                        )
                    _update_progress(
                        job_id,
                        started=started,
                        state="transcribing",
                        phase="transcribing",
                        message=f"Transcribing audio · {int(fraction * 100)}%",
                        progress=asr_start + (asr_weight * fraction),
                        processed_seconds=processed,
                        asr_progress=fraction,
                        eta_seconds=remaining,
                        effective_rtf=(1.0 / rate) if rate else None,
                        asr_eta_seconds=asr_eta,
                        asr_elapsed_seconds=max(0.0, time.time() - generation_started),
                    )

                on_asr_progress(0.0)
                with mlx_progress_callback(on_asr_progress):
                    result_data = normalize_stt_result(
                        stt_model.generate(
                            str(audio_path),
                            verbose=None,
                            chunk_duration=chunk_duration,
                            language=language or None,
                            word_timestamps=True,
                        )
                    )
                on_asr_progress(1.0)
                asr_seconds = time.time() - generation_started
                segments = normalize_segments(result_data.get("segments"))
                atomic_write_json(
                    job_root / "asr.json",
                    {
                        "schema_version": "2.0",
                        "job_id": job_id,
                        "model": model,
                        "language": result_data.get("language"),
                        "text": str(result_data.get("text") or "").strip(),
                        "segments": segments,
                        "word_timestamps": True,
                        "timing": {"asr": asr_seconds},
                    },
                )

            diarization_seconds = 0.0
            speaker_turns: list[dict[str, Any]] | None = None
            if reusable_diarization_checkpoint:
                speaker_turns = normalize_segments(diarization_checkpoint.get("speaker_turns"))
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
                    processed_seconds=total_value,
                    diarization_progress=1.0,
                )
            elif fluid_future is not None:
                stage = "diarizing"
                _update_progress(
                    job_id,
                    started=started,
                    state="diarizing",
                    phase="diarizing",
                    message="Waiting for parallel ANE diarization",
                    progress=asr_end,
                    processed_seconds=total_value,
                    asr_progress=1.0,
                )
                diarization_started = time.time()
                try:
                    speaker_turns = fluid_future.result()
                    fluid_payload = _read_json(job_root / "fluid-diarization.json") or {}
                    diarization_seconds = float(
                        (fluid_payload.get("timing") or {}).get("totalSeconds")
                        or (fluid_payload.get("timing") or {}).get("total_seconds")
                        or time.time() - diarization_started
                    )
                    _update_progress(
                        job_id,
                        started=started,
                        state="diarizing",
                        phase="diarizing",
                        message="Parallel ANE diarization complete",
                        progress=diarization_end,
                        processed_seconds=total_value,
                        diarization_progress=1.0,
                        eta_seconds=0.0,
                        diarization_elapsed_seconds=diarization_seconds,
                    )
                except Exception as exc:
                    execution_mode = "sequential_fallback"
                    scheduler_reason = (
                        f"guardrail:{exc}"
                        if isinstance(exc, ParallelDiarizationAborted)
                        else f"fluid-failed:{type(exc).__name__}"
                    )
                    _store_job_status(
                        job_id,
                        execution_mode=execution_mode,
                        diarization_engine="pyannote",
                        scheduler_reason=scheduler_reason,
                    )

            if speaker_turns is None and diarize:
                stage = "diarizing"
                diarization_started = time.time()

                def on_diarization_progress(fraction: float, step_name: str) -> None:
                    _raise_if_cancelled(cancel_event)
                    fraction = min(1.0, max(0.0, fraction))
                    processed = total_value * fraction
                    rate = telemetry["diarization"].observe(processed).get("rate")
                    diarization_eta = (
                        (total_value - processed) / rate if rate and total_value > processed else None
                    )
                    remaining = diarization_eta
                    if remaining is not None:
                        profiled_merge = _profile_rate(profile, "merge_wall_per_audio")
                        remaining += (
                            total_value * profiled_merge
                            if profiled_merge > 0
                            else (total_value / rate)
                            * (merge_weight / max(diarization_weight, 0.001))
                        )
                    readable_step = step_name.replace("_", " ").capitalize()
                    _update_progress(
                        job_id,
                        started=started,
                        state="diarizing",
                        phase="diarizing",
                        message=f"Detecting speakers · {readable_step}",
                        progress=asr_end + (diarization_weight * fraction),
                        processed_seconds=processed,
                        diarization_progress=fraction,
                        eta_seconds=remaining,
                        effective_rtf=(1.0 / rate) if rate else None,
                        diarization_eta_seconds=diarization_eta,
                        diarization_elapsed_seconds=max(0.0, time.time() - diarization_started),
                    )

                on_diarization_progress(0.0, "segmentation")
                speaker_turns = diarize_speaker_turns(
                    str(audio_path),
                    progress_callback=on_diarization_progress,
                )
                on_diarization_progress(1.0, "complete")
                diarization_seconds = time.time() - diarization_started
            elif speaker_turns is None:
                speaker_turns = []
            atomic_write_json(
                job_root / "diarization.json",
                {
                    "schema_version": "2.0",
                    "job_id": job_id,
                    "enabled": diarize,
                    "speaker_turns": speaker_turns,
                    "engine": "fluidaudio" if execution_mode == "parallel_ane" else "pyannote",
                    "execution_mode": execution_mode,
                    "scheduler_reason": scheduler_reason,
                    "timing": {"diarization": diarization_seconds},
                },
            )

            _raise_if_cancelled(cancel_event)
            stage = "serializing"
            words = extract_asr_words(segments)
            raw_text = str(result_data.get("text") or "").strip()
            if raw_text and not words:
                raise ResponseValidationError(
                    "ASR returned text without word timestamps; schema v2 result was not published"
                )
            attributed_words = attribute_speakers_to_words(words, speaker_turns)
            utterances = assemble_utterances(attributed_words)
            legacy_segments = [
                {
                    "start": utterance["start"],
                    "end": utterance["end"],
                    "speaker": utterance["speaker"],
                    "text": utterance["text"],
                }
                for utterance in utterances
            ]
            merge_started = time.time()
            _update_progress(
                job_id,
                started=started,
                state="merging",
                phase="merging",
                message="Merging and validating result",
                progress=max(asr_end, diarization_end),
                processed_seconds=total_value,
            )
            response_payload = sanitize_finite_numbers(
                {
                    "schema_version": "2.0",
                    "job_id": job_id,
                    "text": formatted_utterances(utterances) or raw_text,
                    "raw_text": raw_text,
                    "words": attributed_words,
                    "speaker_turns": speaker_turns,
                    "utterances": utterances,
                    "asr_segments": segments,
                    "segments": legacy_segments,
                    "language": result_data.get("language"),
                    "backend": (
                        "mlx+fluidaudio" if execution_mode == "parallel_ane"
                        else ("mlx+pyannote" if diarize else "mlx")
                    ),
                    "model": model,
                    "models": {
                        "asr": {"id": model, "word_timestamps": "whisper-cross-attention-dtw"},
                        "diarization": {
                            "id": (
                                "FluidInference/speaker-diarization-coreml"
                                if execution_mode == "parallel_ane"
                                else ("pyannote/speaker-diarization-3.1" if diarize else None)
                            ),
                            "revision": FLUID_MODEL_REVISION if execution_mode == "parallel_ane" else None,
                            "device": (
                                "ane"
                                if execution_mode == "parallel_ane"
                                else ("mps" if diarize and torch.backends.mps.is_available() else "cpu")
                            ),
                        },
                    },
                    "parameters": {
                        "language": language,
                        "diarize": diarize,
                        "chunk_duration": chunk_duration,
                        "execution_mode": execution_mode,
                        "scheduler_reason": scheduler_reason,
                    },
                    "timing": {},
                }
            )
            merge_seconds = time.time() - merge_started
            response_payload["timing"] = {
                "total": time.time() - started,
                "asr": asr_seconds,
                "diarization": diarization_seconds,
                "merge": merge_seconds,
            }
            validate_transcription_response(response_payload)
            atomic_write_json(job_root / "result.json", response_payload)
            if total_value > 0:
                try:
                    _store_hardware_profile(
                        model,
                        diarize,
                        asr_seconds=asr_seconds,
                        diarization_seconds=diarization_seconds,
                        merge_seconds=merge_seconds,
                        audio_seconds=total_value,
                        execution_mode=(
                            "parallel_ane" if execution_mode == "parallel_ane" else "sequential"
                        ),
                    )
                except (OSError, TypeError, ValueError):
                    # A performance-profile write must never invalidate a persisted result.
                    pass
            _store_job_status(
                job_id,
                state="completed",
                phase="completed",
                message="Completed",
                progress=1.0,
                asr_progress=1.0,
                diarization_progress=1.0,
                processed_seconds=total_value,
                elapsed_seconds=max(0.0, time.time() - started),
                eta_seconds=0.0,
                asr_elapsed_seconds=asr_seconds,
                diarization_elapsed_seconds=diarization_seconds,
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
    finally:
        fluid_abort_event.set()
        if fluid_executor is not None:
            fluid_executor.shutdown(wait=True, cancel_futures=True)


def _start_background_job(job_id: str, audio_path: Path, **parameters: Any) -> None:
    async def runner():
        try:
            await asyncio.to_thread(_run_transcription_job, job_id, audio_path, **parameters)
        finally:
            with _jobs_lock:
                _job_tasks.pop(job_id, None)
                _job_telemetry.pop(job_id, None)

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
            _job_telemetry.pop(job_id, None)
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
