#!/usr/bin/env python3
import json
import os
import tempfile
import time
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from mlx_audio.stt.utils import load_model


DEFAULT_MODEL = os.getenv(
    "CONTORA_MLX_MODEL",
    "mlx-community/whisper-large-v3-turbo-asr-fp16",
)
RUNTIME_ROOT = Path(os.environ["CONTORA_WHISPER_RUNTIME_ROOT"])

app = FastAPI(title="Contora MLX transcription server")
_models: dict[str, Any] = {}
_diarization_pipeline = None


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

    import torch
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(str(local_pyannote_config()))
    pipeline.to(torch.device("mps") if torch.backends.mps.is_available() else torch.device("cpu"))
    _diarization_pipeline = pipeline
    return pipeline


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
        item = dict(segment)
        item["speaker"] = best_speaker
        labelled.append(item)
    return labelled


def formatted_text(segments: list[dict[str, Any]]) -> str:
    lines: list[str] = []
    for segment in segments:
        text = str(segment.get("text") or "").strip()
        if not text:
            continue
        start = timestamp(float(segment.get("start") or 0.0))
        end = timestamp(float(segment.get("end") or 0.0))
        speaker = str(segment.get("speaker") or "SPEAKER_00")
        lines.append(f"[{start} --> {end}] [{speaker}]: {text}")
    return "\n".join(lines)


def normalize_stt_result(result: Any) -> dict[str, Any]:
    if isinstance(result, dict):
        return result
    if is_dataclass(result):
        return asdict(result)
    return {
        "text": getattr(result, "text", ""),
        "segments": getattr(result, "segments", []),
        "language": getattr(result, "language", None),
    }


@app.get("/health")
def health():
    return {
        "status": "ok",
        "backend": "mlx",
        "defaultModel": DEFAULT_MODEL,
        "loadedModels": list(_models),
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
    diarize: bool = Form(False),
    chunk_duration: float = Form(30.0),
):
    suffix = Path(file.filename or "audio.wav").suffix or ".wav"
    started = time.time()
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        audio_path = tmp.name
        tmp.write(await file.read())

    try:
        stt_model = model_for(model)
        generation_started = time.time()
        result = stt_model.generate(
            audio_path,
            verbose=None,
            chunk_duration=chunk_duration,
            language=language or None,
        )
        result_data = normalize_stt_result(result)
        asr_seconds = time.time() - generation_started
        segments = list(result_data.get("segments") or [])

        diarization_seconds = 0.0
        if diarize:
            diarization_started = time.time()
            segments = assign_speakers(audio_path, segments)
            diarization_seconds = time.time() - diarization_started
        else:
            for segment in segments:
                segment.setdefault("speaker", "SPEAKER_00")

        text = formatted_text(segments)
        return {
            "text": text or str(result_data.get("text") or "").strip(),
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
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    finally:
        try:
            os.remove(audio_path)
        except OSError:
            pass


def main():
    host = os.getenv("CONTORA_MLX_HOST", "127.0.0.1")
    port = int(os.getenv("CONTORA_MLX_PORT", "8010"))
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
