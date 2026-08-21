#!/usr/bin/env python3
"""JSON-boundary safety helpers for the Contora MLX server."""

from __future__ import annotations

import json
import math
import os
import tempfile
from collections.abc import Mapping
from dataclasses import asdict, is_dataclass
from pathlib import Path
from typing import Any


class ResponseValidationError(ValueError):
    pass


def sanitize_finite_numbers(value: Any) -> Any:
    """Return a JSON-compatible copy with every non-finite number replaced by None."""
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if is_dataclass(value):
        return sanitize_finite_numbers(asdict(value))
    model_dump = getattr(value, "model_dump", None)
    if callable(model_dump):
        return sanitize_finite_numbers(model_dump())
    if isinstance(value, Mapping):
        return {str(key): sanitize_finite_numbers(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [sanitize_finite_numbers(item) for item in value]

    # NumPy/MLX arrays and scalars expose tolist()/item().
    to_list = getattr(value, "tolist", None)
    if callable(to_list):
        try:
            return sanitize_finite_numbers(to_list())
        except (TypeError, ValueError):
            pass
    item = getattr(value, "item", None)
    if callable(item):
        try:
            return sanitize_finite_numbers(item())
        except (TypeError, ValueError):
            pass
    if hasattr(value, "__dict__"):
        return sanitize_finite_numbers(vars(value))
    return str(value)


def _require_type(payload: dict[str, Any], key: str, expected: type | tuple[type, ...]) -> None:
    if key not in payload or not isinstance(payload[key], expected):
        raise ResponseValidationError(f"{key!r} has an invalid or missing value")


def validate_transcription_response(payload: Any) -> dict[str, Any]:
    """Validate the stable v1 response envelope before it reaches FastAPI."""
    if not isinstance(payload, dict):
        raise ResponseValidationError("response must be an object")

    _require_type(payload, "schema_version", str)
    _require_type(payload, "job_id", str)
    _require_type(payload, "text", str)
    _require_type(payload, "raw_text", str)
    _require_type(payload, "segments", list)
    _require_type(payload, "backend", str)
    _require_type(payload, "model", str)
    _require_type(payload, "timing", dict)

    language = payload.get("language")
    if language is not None and not isinstance(language, str):
        raise ResponseValidationError("'language' must be a string or null")

    for index, segment in enumerate(payload["segments"]):
        if not isinstance(segment, dict):
            raise ResponseValidationError(f"segments[{index}] must be an object")
        for key in ("start", "end"):
            number = segment.get(key)
            if number is not None and (not isinstance(number, (int, float)) or isinstance(number, bool)):
                raise ResponseValidationError(f"segments[{index}].{key} must be a number or null")
            if isinstance(number, float) and not math.isfinite(number):
                raise ResponseValidationError(f"segments[{index}].{key} must be finite or null")
        for key in ("text", "speaker"):
            item = segment.get(key)
            if item is not None and not isinstance(item, str):
                raise ResponseValidationError(f"segments[{index}].{key} must be a string or null")

    for key in ("total", "asr", "diarization"):
        number = payload["timing"].get(key)
        if not isinstance(number, (int, float)) or isinstance(number, bool) or not math.isfinite(float(number)):
            raise ResponseValidationError(f"timing.{key} must be a finite number")
    return payload


def strict_json_bytes(payload: Any, *, pretty: bool = False) -> bytes:
    sanitized = sanitize_finite_numbers(payload)
    return json.dumps(
        sanitized,
        ensure_ascii=False,
        allow_nan=False,
        indent=2 if pretty else None,
        separators=None if pretty else (",", ":"),
    ).encode("utf-8")


def atomic_write_json(path: Path, payload: Any) -> Path:
    """Write strict JSON to a temporary sibling and atomically publish it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = strict_json_bytes(payload, pretty=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise
    return path
