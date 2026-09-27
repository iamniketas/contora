from __future__ import annotations

import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote, urlsplit, urlunsplit

import requests


class PipelineError(RuntimeError):
    """A safe, user-facing pipeline failure."""


class PipelineCancelled(PipelineError):
    pass


@dataclass(frozen=True)
class PipelineConfig:
    speech_base_url: str
    speech_token: str
    speech_model: str
    upload_base_url: str
    upload_max_days: int | None
    connect_timeout_seconds: float
    read_timeout_seconds: float
    poll_interval_seconds: float
    operation_timeout_seconds: float
    runtime_root: Path | None
    diarization_device: str
    num_speakers: int | None = None

    @classmethod
    def from_env(cls) -> "PipelineConfig":
        speech_base_url = os.getenv("SPEECH_API_BASE_URL", "").strip().rstrip("/")
        speech_token = os.getenv("SPEECH_API_TOKEN", "").strip()
        upload_base_url = os.getenv("CONTORA_VK_UPLOAD_BASE_URL", "").strip().rstrip("/")
        missing = [
            name
            for name, value in (
                ("SPEECH_API_BASE_URL", speech_base_url),
                ("SPEECH_API_TOKEN", speech_token),
                ("CONTORA_VK_UPLOAD_BASE_URL", upload_base_url),
            )
            if not value
        ]
        if missing:
            raise PipelineError(f"Missing required environment variables: {', '.join(missing)}")

        runtime_value = os.getenv("CONTORA_SPEECH_RUNTIME_ROOT", "").strip()
        max_days_value = os.getenv("CONTORA_VK_UPLOAD_MAX_DAYS", "1").strip()
        num_speakers_value = os.getenv("CONTORA_VK_NUM_SPEAKERS", "").strip()
        try:
            num_speakers = int(num_speakers_value) if num_speakers_value else None
        except ValueError as exc:
            raise PipelineError("CONTORA_VK_NUM_SPEAKERS must be an integer") from exc
        if num_speakers is not None and not 1 <= num_speakers <= 50:
            raise PipelineError("CONTORA_VK_NUM_SPEAKERS must be between 1 and 50")

        return cls(
            speech_base_url=speech_base_url,
            speech_token=speech_token,
            speech_model=os.getenv("SPEECH_API_MODEL", "latest").strip() or "latest",
            upload_base_url=upload_base_url,
            upload_max_days=int(max_days_value) if max_days_value else None,
            connect_timeout_seconds=float(os.getenv("CONTORA_VK_HTTP_CONNECT_TIMEOUT_SECONDS", "30")),
            read_timeout_seconds=float(os.getenv("CONTORA_VK_HTTP_READ_TIMEOUT_SECONDS", "300")),
            poll_interval_seconds=float(os.getenv("CONTORA_VK_POLL_INTERVAL_SECONDS", "5")),
            operation_timeout_seconds=float(os.getenv("CONTORA_VK_OPERATION_TIMEOUT_SECONDS", "43200")),
            runtime_root=Path(runtime_value).expanduser() if runtime_value else None,
            diarization_device=os.getenv("CONTORA_VK_DIARIZATION_DEVICE", "auto").strip().lower(),
            num_speakers=num_speakers,
        )


@dataclass(frozen=True)
class PipelineProgress:
    phase: str
    progress: float
    message: str
    processed_seconds: float | None = None
    total_seconds: float | None = None


ProgressCallback = Callable[[PipelineProgress], None]


def _default_progress(_: PipelineProgress) -> None:
    return


def audio_duration_seconds(path: Path) -> float | None:
    try:
        with wave.open(str(path), "rb") as audio:
            rate = audio.getframerate()
            return audio.getnframes() / rate if rate > 0 else None
    except (OSError, EOFError, wave.Error):
        pass

    # Contora's handoff WAV uses IEEE float32 (format tag 3), which Python's
    # wave module does not accept. Read just the RIFF chunk headers so duration
    # is available without decoding or transcoding the full recording.
    try:
        with path.open("rb") as stream:
            if stream.read(4) != b"RIFF":
                return None
            stream.seek(8)
            if stream.read(4) != b"WAVE":
                return None
            byte_rate: int | None = None
            data_size: int | None = None
            while True:
                header = stream.read(8)
                if len(header) != 8:
                    break
                chunk_id, chunk_size = struct.unpack("<4sI", header)
                if chunk_id == b"fmt ":
                    payload = stream.read(chunk_size)
                    if len(payload) >= 12:
                        byte_rate = struct.unpack_from("<I", payload, 8)[0]
                elif chunk_id == b"data":
                    data_size = chunk_size
                    break
                else:
                    stream.seek(chunk_size, 1)
                if chunk_size % 2:
                    stream.seek(1, 1)
            return data_size / byte_rate if data_size is not None and byte_rate else None
    except (OSError, struct.error):
        return None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def prepare_canonical_audio(source: Path, destination: Path) -> None:
    ffmpeg = os.getenv("CONTORA_FFMPEG_EXE", "").strip() or shutil.which("ffmpeg")
    if not ffmpeg:
        raise PipelineError("ffmpeg is required to prepare canonical audio")
    destination.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-vn",
            "-map",
            "0:a:0",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "64k",
            str(destination),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if process.returncode != 0 or not destination.is_file():
        detail = process.stderr.strip()[-2000:]
        raise PipelineError(f"ffmpeg audio preparation failed: {detail or process.returncode}")


def upload_transfer(path: Path, config: PipelineConfig, cancel: threading.Event) -> str:
    if cancel.is_set():
        raise PipelineCancelled("Cancelled")
    remote_name = f"{uuid.uuid4().hex}-{path.name}"
    upload_url = f"{config.upload_base_url}/{quote(remote_name)}"
    headers = {}
    if config.upload_max_days is not None:
        headers["Max-Days"] = str(config.upload_max_days)
    try:
        with path.open("rb") as stream:
            response = requests.put(
                upload_url,
                data=stream,
                headers=headers,
                timeout=(config.connect_timeout_seconds, max(3600.0, config.read_timeout_seconds)),
            )
        response.raise_for_status()
    except requests.RequestException as exc:
        raise PipelineError(f"Audio upload failed: {exc}") from exc
    return response.text.strip() or upload_url


def _speech_headers(config: PipelineConfig) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {config.speech_token}",
        "Content-Type": "application/json",
    }


def _recover_operation_after_start_timeout(
    correlation_id: str,
    config: PipelineConfig,
    cancel: threading.Event,
) -> dict[str, Any] | None:
    timeout = (config.connect_timeout_seconds, config.read_timeout_seconds)
    for _ in range(3):
        if cancel.wait(2.0):
            raise PipelineCancelled("Cancelled while recovering Speech API operation")
        try:
            response = requests.get(
                f"{config.speech_base_url}/v1/operations/asr",
                headers=_speech_headers(config),
                params={"correlationId": correlation_id},
                timeout=timeout,
            )
            if response.status_code == 404:
                continue
            response.raise_for_status()
            operation = response.json()
        except (requests.RequestException, ValueError):
            continue
        if isinstance(operation, dict) and operation.get("operationId"):
            return operation
    return None


def recognize_long_audio(
    audio_uri: str,
    config: PipelineConfig,
    cancel: threading.Event,
    progress: ProgressCallback,
    total_seconds: float | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    correlation_id = f"contora-{uuid.uuid4().hex}"
    request_payload = {
        "model": config.speech_model,
        "audio": {"uri": audio_uri},
        "options": {
            "enable_profanity_filter": True,
            "raw_text": False,
            "return_segments": True,
        },
        "correlationId": correlation_id,
    }
    timeout = (config.connect_timeout_seconds, config.read_timeout_seconds)
    try:
        response = requests.post(
            f"{config.speech_base_url}/v1/speech/asr:recognize-lro",
            headers=_speech_headers(config),
            json=request_payload,
            timeout=timeout,
        )
        response.raise_for_status()
        operation = response.json()
    except requests.Timeout as exc:
        operation = _recover_operation_after_start_timeout(correlation_id, config, cancel)
        if operation is None:
            raise PipelineError(
                f"Speech API start timed out and no operation was found (correlationId={correlation_id})"
            ) from exc
    except (requests.RequestException, ValueError) as exc:
        raise PipelineError(f"Speech API start failed (correlationId={correlation_id}): {exc}") from exc

    operation_id = operation.get("operationId")
    if not isinstance(operation_id, str) or not operation_id:
        raise PipelineError("Speech API start response has no operationId")

    deadline = time.monotonic() + config.operation_timeout_seconds
    status_history: list[dict[str, Any]] = []
    last_status: str | None = None
    while True:
        if cancel.wait(config.poll_interval_seconds if last_status is not None else 0):
            raise PipelineCancelled("Cancelled while waiting for Speech API")
        try:
            poll_response = requests.get(
                f"{config.speech_base_url}/v1/operations/asr",
                headers=_speech_headers(config),
                params={"operationId": operation_id},
                timeout=timeout,
            )
            poll_response.raise_for_status()
            current = poll_response.json()
        except (requests.RequestException, ValueError) as exc:
            if time.monotonic() >= deadline:
                raise PipelineError(f"Speech API polling failed until deadline: {exc}") from exc
            continue

        status = str(current.get("status") or "UNKNOWN").upper()
        if status != last_status:
            status_history.append({"observed_at": time.time(), "status": status})
            progress(
                PipelineProgress(
                    phase="transcribing",
                    progress=0.05 if status == "PENDING" else 0.50 if status == "RUNNING" else 1.0,
                    message=f"Corporate ASR · {status}",
                    processed_seconds=total_seconds if status == "DONE" else None,
                    total_seconds=total_seconds,
                )
            )
            last_status = status
        if status == "DONE":
            result = current.get("response")
            if not isinstance(result, dict):
                raise PipelineError("DONE Speech API operation has no response object")
            return result, {
                "operation_id": operation_id,
                "correlation_id": correlation_id,
                "status_history": status_history,
            }
        if status in {"FAILED", "CANCELLED"}:
            raise PipelineError(str(current.get("errorMessage") or status))
        if time.monotonic() >= deadline:
            raise PipelineError(f"Speech API operation timed out: {operation_id}")


_DIARIZATION_PIPELINE: Any = None
_DIARIZATION_LOCK = threading.Lock()


def _local_pyannote_config(runtime_root: Path) -> Path:
    source = runtime_root / "pyannote" / "speaker-diarization-3.1" / "config.yaml"
    if not source.is_file():
        raise PipelineError(f"pyannote config not found: {source}")
    destination = runtime_root / "pyannote" / "speaker-diarization-3.1.contora-vk.local.yaml"
    text = source.read_text(encoding="utf-8")
    text = text.replace(
        "segmentation: pyannote/segmentation-3.0",
        "\n".join(
            [
                "segmentation:",
                f"      checkpoint: {runtime_root / 'pyannote' / 'segmentation-3.0' / 'pytorch_model.bin'}",
            ]
        ),
    )
    text = text.replace(
        "embedding: pyannote/wespeaker-voxceleb-resnet34-LM",
        "\n".join(
            [
                "embedding:",
                f"      checkpoint: {runtime_root / 'pyannote' / 'wespeaker-voxceleb-resnet34-LM' / 'pytorch_model.bin'}",
            ]
        ),
    )
    destination.write_text(text, encoding="utf-8")
    return destination


def diarize_local(
    audio_path: Path,
    config: PipelineConfig,
    cancel: threading.Event,
    progress: ProgressCallback,
    total_seconds: float | None,
) -> list[dict[str, Any]]:
    if config.runtime_root is None:
        raise PipelineError("CONTORA_SPEECH_RUNTIME_ROOT is required for local diarization")
    try:
        import torch
        from pyannote.audio import Pipeline
    except ImportError as exc:
        raise PipelineError("pyannote.audio and torch are required for diarization") from exc

    global _DIARIZATION_PIPELINE
    with _DIARIZATION_LOCK:
        if _DIARIZATION_PIPELINE is None:
            pipeline = Pipeline.from_pretrained(str(_local_pyannote_config(config.runtime_root)))
            requested = config.diarization_device
            if requested == "auto":
                requested = "mps" if torch.backends.mps.is_available() else "cpu"
            pipeline.to(torch.device(requested))
            _DIARIZATION_PIPELINE = pipeline
        pipeline = _DIARIZATION_PIPELINE

    def hook(step_name: str, _artifact: Any, file: Any = None, total: Any = None, completed: Any = None) -> None:
        del file
        if cancel.is_set():
            raise PipelineCancelled("Cancelled during diarization")
        fraction = 0.5
        if total and completed is not None:
            fraction = min(1.0, max(0.0, float(completed) / float(total)))
        normalized_step = str(step_name).replace("_", " ")
        stage_ranges = {
            "segmentation": (0.0, 0.18),
            "speaker counting": (0.18, 0.20),
            "embeddings": (0.20, 0.90),
            "clustering": (0.90, 0.97),
            "discrete diarization": (0.97, 1.0),
        }
        lower, upper = stage_ranges.get(normalized_step, (0.0, 1.0))
        stage_progress = lower + ((upper - lower) * fraction)
        progress(
            PipelineProgress(
                phase="diarizing",
                progress=stage_progress,
                message=f"Local diarization · {normalized_step}",
                processed_seconds=(total_seconds or 0.0) * fraction,
                total_seconds=total_seconds,
            )
        )

    diarization = pipeline(str(audio_path), hook=hook)
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
    return sorted(turns, key=lambda item: (item["start"], item["end"], item["speaker"]))


def normalize_asr_segments(response: dict[str, Any]) -> list[dict[str, Any]]:
    normalized: list[dict[str, Any]] = []
    for index, raw in enumerate(response.get("segments") or []):
        if not isinstance(raw, dict):
            continue
        try:
            start_ms = int(raw.get("startTimeMs", raw.get("start_time_ms", 0)))
            end_ms = int(raw.get("endTimeMs", raw.get("end_time_ms", start_ms)))
        except (TypeError, ValueError):
            continue
        text = str(raw.get("text") or "").strip()
        if not text:
            continue
        raw_confidence = raw.get("confidence", response.get("confidence"))
        try:
            confidence = float(raw_confidence) if raw_confidence is not None else None
        except (TypeError, ValueError):
            confidence = None
        start = max(0.0, start_ms / 1000.0)
        end = max(start, end_ms / 1000.0)
        normalized.append(
            {
                "text": text,
                "start": start,
                "end": end,
                "confidence": confidence,
                "asr_segment_index": index,
            }
        )
    return normalized


def _overlap_scores(start: float, end: float, turns: list[dict[str, Any]]) -> dict[str, float]:
    scores: dict[str, float] = {}
    for turn in turns:
        overlap = max(0.0, min(end, float(turn["end"])) - max(start, float(turn["start"])))
        if overlap > 0:
            speaker = str(turn["speaker"])
            scores[speaker] = scores.get(speaker, 0.0) + overlap
    return scores


def consolidate_speaker_turns(
    turns: list[dict[str, Any]],
    target_speakers: int | None,
) -> list[dict[str, Any]]:
    """Fold short over-clusters into the dominant long-lived speakers.

    Forcing pyannote's clustering to an exact count can merge two dominant
    speakers while retaining a short outlier. Keeping the dominant automatic
    clusters and remapping only minor turns proved safer on the observed Zoom
    recording. Each minor turn follows an overlapping dominant speaker when
    available, otherwise the nearest dominant turn on the timeline.
    """
    if not turns or target_speakers is None:
        return list(turns)

    durations: dict[str, float] = {}
    for turn in turns:
        speaker = str(turn["speaker"])
        durations[speaker] = durations.get(speaker, 0.0) + max(
            0.0, float(turn["end"]) - float(turn["start"])
        )
    if len(durations) <= target_speakers:
        return list(turns)

    dominant = {
        speaker
        for speaker, _ in sorted(durations.items(), key=lambda item: (-item[1], item[0]))[
            :target_speakers
        ]
    }
    dominant_turns = [turn for turn in turns if str(turn["speaker"]) in dominant]
    remapped: list[dict[str, Any]] = []
    for turn in turns:
        if str(turn["speaker"]) in dominant:
            remapped.append(dict(turn))
            continue
        overlap_by_speaker: dict[str, float] = {}
        for candidate in dominant_turns:
            overlap = max(
                0.0,
                min(float(turn["end"]), float(candidate["end"]))
                - max(float(turn["start"]), float(candidate["start"])),
            )
            if overlap > 0:
                speaker = str(candidate["speaker"])
                overlap_by_speaker[speaker] = overlap_by_speaker.get(speaker, 0.0) + overlap
        if overlap_by_speaker:
            replacement = sorted(
                overlap_by_speaker.items(), key=lambda item: (-item[1], item[0])
            )[0][0]
        else:
            midpoint = (float(turn["start"]) + float(turn["end"])) / 2.0
            nearest = min(
                dominant_turns,
                key=lambda candidate: min(
                    abs(midpoint - float(candidate["start"])),
                    abs(midpoint - float(candidate["end"])),
                ),
            )
            replacement = str(nearest["speaker"])
        remapped.append({**turn, "speaker": replacement})
    return sorted(remapped, key=lambda item: (item["start"], item["end"], item["speaker"]))


def attribute_speakers(
    segments: list[dict[str, Any]],
    turns: list[dict[str, Any]],
    *,
    minimum_overlap_ratio: float = 0.10,
    ambiguity_ratio: float = 0.90,
    boundary_tolerance_seconds: float = 0.25,
) -> list[dict[str, Any]]:
    attributed: list[dict[str, Any]] = []
    previous_speaker: str | None = None
    for segment in segments:
        start = float(segment["start"])
        end = max(start, float(segment["end"]))
        duration = max(0.001, end - start)
        midpoint = start + ((end - start) / 2.0)
        ranked = sorted(_overlap_scores(start, end, turns).items(), key=lambda item: (-item[1], item[0]))
        top_score = ranked[0][1] if ranked else 0.0
        close = [speaker for speaker, score in ranked if top_score > 0 and score / top_score >= ambiguity_ratio]
        ambiguous = len(close) > 1

        # A near-tie is useful diagnostic information, but it must not erase the
        # speaker label. Prefer the speaker active at the word midpoint, then
        # continuity with the preceding word, and finally the largest overlap.
        if ranked:
            midpoint_speakers = {
                str(turn["speaker"])
                for turn in turns
                if float(turn["start"]) <= midpoint <= float(turn["end"])
            }
            midpoint_close = sorted(midpoint_speakers.intersection(close))
            if len(midpoint_close) == 1:
                speaker = midpoint_close[0]
            elif previous_speaker in close:
                speaker = str(previous_speaker)
            else:
                speaker = ranked[0][0]
        elif turns:
            # Word-level VK timestamps are often only ~80 ms long and can fall
            # into tiny pyannote VAD boundary gaps. Attribute those words to the
            # nearest turn instead of producing unusable UNKNOWN fragments.
            nearest = min(
                turns,
                key=lambda turn: min(
                    abs(midpoint - float(turn["start"])),
                    abs(midpoint - float(turn["end"])),
                ),
            )
            nearest_distance = min(
                abs(midpoint - float(nearest["start"])),
                abs(midpoint - float(nearest["end"])),
            )
            if previous_speaker is not None and nearest_distance > boundary_tolerance_seconds:
                speaker = previous_speaker
            else:
                speaker = str(nearest["speaker"])
        else:
            speaker = "UNKNOWN"

        overlap_ratio = top_score / duration
        item = dict(segment)
        item.update(
            {
                "speaker": speaker,
                "speaker_score": min(1.0, max(0.0, overlap_ratio)),
                "overlap": ambiguous or (bool(ranked) and overlap_ratio < minimum_overlap_ratio),
                "overlap_speakers": close if ambiguous else [],
            }
        )
        attributed.append(item)
        if speaker != "UNKNOWN":
            previous_speaker = speaker
    return attributed


def assemble_utterances(words: list[dict[str, Any]]) -> list[dict[str, Any]]:
    utterances: list[dict[str, Any]] = []
    for index, word in enumerate(words):
        text = str(word.get("text") or "").strip()
        if not text:
            continue
        if (
            utterances
            and utterances[-1]["speaker"] == word["speaker"]
            and float(word["start"]) - float(utterances[-1]["end"]) <= 1.5
            and len(utterances[-1]["text"]) + len(text) < 500
        ):
            utterances[-1]["end"] = float(word["end"])
            utterances[-1]["text"] = f"{utterances[-1]['text']} {text}".strip()
            utterances[-1]["word_end_index"] = index + 1
            utterances[-1]["overlap"] = utterances[-1]["overlap"] or bool(word["overlap"])
        else:
            utterances.append(
                {
                    "start": float(word["start"]),
                    "end": float(word["end"]),
                    "speaker": str(word["speaker"]),
                    "text": text,
                    "word_start_index": index,
                    "word_end_index": index + 1,
                    "overlap": bool(word["overlap"]),
                }
            )
    return utterances


def formatted_utterances(utterances: list[dict[str, Any]]) -> str:
    def stamp(value: float) -> str:
        milliseconds = max(0, int(round(value * 1000)))
        hours, remainder = divmod(milliseconds, 3_600_000)
        minutes, remainder = divmod(remainder, 60_000)
        seconds, millis = divmod(remainder, 1000)
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{millis:03d}"

    return "\n".join(
        f"[{stamp(float(item['start']))} --> {stamp(float(item['end']))}] "
        f"[{item['speaker']}]: {item['text']}"
        for item in utterances
    )


def _redacted_uri(uri: str) -> dict[str, str]:
    parts = urlsplit(uri)
    safe = urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    return {"redacted": safe, "sha256": hashlib.sha256(uri.encode("utf-8")).hexdigest()}


def recognition_quality(response: dict[str, Any], segments: list[dict[str, Any]]) -> dict[str, Any]:
    warnings: list[str] = []
    incomplete_reasons: list[str] = []
    metadata = response.get("metadata") if isinstance(response.get("metadata"), dict) else {}
    raw_effective = metadata.get("effectiveDurationMs")
    raw_total = metadata.get("totalDurationMs")
    try:
        effective_ms = int(raw_effective) if raw_effective is not None else None
    except (TypeError, ValueError):
        effective_ms = None
    try:
        total_ms = int(raw_total) if raw_total is not None else None
    except (TypeError, ValueError):
        total_ms = None
    last_segment_ms = int(round(float(segments[-1]["end"]) * 1000)) if segments else 0
    coverage_ratio = last_segment_ms / total_ms if total_ms and total_ms > 0 else None
    if effective_ms == 0:
        if coverage_ratio is not None and coverage_ratio >= 0.95:
            warnings.append("effectiveDurationMs is zero; accepted because timed segments cover the audio")
        else:
            warning = "effectiveDurationMs is zero"
            warnings.append(warning)
            incomplete_reasons.append(warning)
    if not segments:
        warning = "timed segments are empty"
        warnings.append(warning)
        incomplete_reasons.append(warning)
    if segments and float(segments[-1]["end"]) <= 0:
        warning = "last segment does not cover positive audio time"
        warnings.append(warning)
        incomplete_reasons.append(warning)
    return {
        "status": "incomplete" if incomplete_reasons else "complete",
        "warnings": warnings,
        "segment_coverage_ratio": coverage_ratio,
    }


def run_pipeline(
    source_audio: Path,
    job_id: str,
    output_root: Path,
    *,
    enable_diarization: bool,
    cancel: threading.Event,
    progress: ProgressCallback = _default_progress,
    config: PipelineConfig | None = None,
    diarizer: Callable[[Path, PipelineConfig, threading.Event, ProgressCallback, float | None], list[dict[str, Any]]] = diarize_local,
) -> dict[str, Any]:
    config = config or PipelineConfig.from_env()
    total_seconds = audio_duration_seconds(source_audio)
    job_root = output_root / job_id
    job_root.mkdir(parents=True, exist_ok=True)
    started = time.time()
    progress(PipelineProgress("preparing", 0.02, "Preparing canonical audio", 0, total_seconds))

    canonical_audio = job_root / "canonical.mp3"
    prepare_canonical_audio(source_audio, canonical_audio)
    progress(PipelineProgress("uploading", 0.08, "Uploading audio to approved storage", 0, total_seconds))
    audio_uri = upload_transfer(canonical_audio, config, cancel)

    diarization_started = time.time()
    with ThreadPoolExecutor(max_workers=2, thread_name_prefix="contora-vk") as executor:
        diarization_future = (
            executor.submit(diarizer, source_audio, config, cancel, progress, total_seconds)
            if enable_diarization
            else None
        )
        asr_started = time.time()
        asr_response, operation = recognize_long_audio(audio_uri, config, cancel, progress, total_seconds)
        asr_seconds = time.time() - asr_started
        if diarization_future is not None:
            speaker_turns = consolidate_speaker_turns(
                diarization_future.result(), config.num_speakers
            )
            diarization_seconds = time.time() - diarization_started
        else:
            speaker_turns = []
            diarization_seconds = 0.0

    if cancel.is_set():
        raise PipelineCancelled("Cancelled")
    raw_text = str(asr_response.get("transcript") or "").strip()
    asr_segments = normalize_asr_segments(asr_response)
    if raw_text and not asr_segments:
        raise PipelineError("Speech API returned text without timed segments")
    if not raw_text:
        raise PipelineError("Speech API returned an empty transcript")

    merge_started = time.time()
    attributed = attribute_speakers(asr_segments, speaker_turns) if enable_diarization else [
        {
            **segment,
            "speaker": "SPEAKER_00",
            "speaker_score": 1.0,
            "overlap": False,
            "overlap_speakers": [],
        }
        for segment in asr_segments
    ]
    utterances = assemble_utterances(attributed)
    legacy_segments = [
        {key: item[key] for key in ("start", "end", "speaker", "text")}
        for item in utterances
    ]
    quality = recognition_quality(asr_response, asr_segments)
    merge_seconds = time.time() - merge_started
    result = {
        "schema_version": "2.0",
        "job_id": job_id,
        "text": formatted_utterances(utterances) or raw_text,
        "raw_text": raw_text,
        "words": attributed,
        "speaker_turns": speaker_turns,
        "utterances": utterances,
        "asr_segments": asr_segments,
        "segments": legacy_segments,
        "language": "ru-observed-not-declared",
        "backend": "corporate-asr+local-pyannote" if enable_diarization else "corporate-asr",
        "model": config.speech_model,
        "models": {
            "asr": {"id": config.speech_model, "provider": "corporate"},
            "diarization": {"id": "pyannote/speaker-diarization-3.1" if enable_diarization else None},
        },
        "parameters": {"diarize": enable_diarization, "num_speakers": config.num_speakers},
        "quality": quality,
        "timing": {
            "total": time.time() - started,
            "asr": asr_seconds,
            "diarization": diarization_seconds,
            "merge": max(0.0, merge_seconds),
        },
    }
    diagnostics = {
        "schema_version": "1.0",
        "job_id": job_id,
        "source_sha256": file_sha256(source_audio),
        "audio_uri": _redacted_uri(audio_uri),
        "speech": {
            "base_url": config.speech_base_url,
            "model": config.speech_model,
            **operation,
        },
        "response": asr_response,
    }
    (job_root / "diagnostics.json").write_text(
        json.dumps(diagnostics, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    progress(PipelineProgress("completed", 1.0, "Completed", total_seconds, total_seconds))
    return result
