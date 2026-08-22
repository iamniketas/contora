from __future__ import annotations

import dataclasses
import json
import math
import os
from pathlib import Path
from typing import Any


def require_model_revision(model_root: Path, expected_revision: str) -> None:
    marker = model_root / ".contora-model-revision"
    try:
        actual = marker.read_text(encoding="utf-8").strip()
    except OSError as exc:
        resolved = model_root.resolve()
        if resolved.name == expected_revision and resolved.parent.name == "snapshots":
            return
        raise RuntimeError(f"missing pinned model marker: {marker}") from exc
    if actual != expected_revision:
        raise RuntimeError(
            f"model revision mismatch for {model_root}: expected {expected_revision}, got {actual}"
        )


def json_safe(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return json_safe(dataclasses.asdict(value))
    if isinstance(value, dict):
        return {str(key): json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, (str, int, bool)) or value is None:
        return value
    model_dump = getattr(value, "model_dump", None)
    if callable(model_dump):
        return json_safe(model_dump())
    if hasattr(value, "__dict__"):
        return json_safe(vars(value))
    return str(value)


def atomic_write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(
        json.dumps(json_safe(payload), ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False)
        + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def canonical_asr(result: Any, *, engine: dict[str, Any], timing: dict[str, float]) -> dict[str, Any]:
    normalized = json_safe(result)
    if not isinstance(normalized, dict):
        raise ValueError("ASR engine returned a non-object result")
    segments: list[dict[str, Any]] = []
    canonical_words: list[dict[str, Any]] = []
    for index, source in enumerate(normalized.get("segments") or []):
        segment = dict(source)
        canonical_segment = {
            "id": segment.get("id", index),
            "start": float(segment.get("start") or 0.0),
            "end": float(segment.get("end") or segment.get("start") or 0.0),
            "text": str(segment.get("text") or ""),
        }
        for key in ("avg_logprob", "avgLogprob", "no_speech_prob", "noSpeechProb", "temperature"):
            if key in segment:
                canonical_segment[key] = segment[key]
        segment_words: list[dict[str, Any]] = []
        for word in segment.get("words") or []:
            item = {
                "text": str(word.get("word", word.get("text", ""))),
                "start": float(word.get("start") or 0.0),
                "end": float(word.get("end") or word.get("start") or 0.0),
                "confidence": word.get("probability", word.get("confidence")),
            }
            segment_words.append(item)
            canonical_words.append(item)
        canonical_segment["words"] = segment_words
        segments.append(canonical_segment)
    return {
        "schema_version": "1.0",
        "kind": "asr",
        "engine": engine,
        "text": str(normalized.get("text") or "").strip(),
        "language": normalized.get("language"),
        "segments": segments,
        "words": canonical_words,
        "speaker_turns": [],
        "timing": timing,
    }
