from __future__ import annotations

import hashlib
import json
import math
import os
import wave
from pathlib import Path
from typing import Any


class BenchmarkConfigError(ValueError):
    pass


def read_json(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BenchmarkConfigError(f"cannot read {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise BenchmarkConfigError(f"{path} must contain a JSON object")
    return payload


def atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def resolve_path(base: Path, value: str) -> Path:
    expanded = Path(os.path.expandvars(os.path.expanduser(value)))
    return expanded.resolve() if expanded.is_absolute() else (base / expanded).resolve()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prediction_semantic_sha256(payload: dict[str, Any]) -> str:
    """Hash user-visible prediction content while excluding timings/diagnostics."""
    semantic = {
        key: payload.get(key)
        for key in ("kind", "language", "text", "segments", "words", "speaker_turns", "utterances")
        if key in payload
    }
    encoded = json.dumps(
        semantic, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def wav_duration(path: Path) -> float | None:
    try:
        with wave.open(str(path), "rb") as handle:
            rate = handle.getframerate()
            return handle.getnframes() / rate if rate else None
    except (OSError, EOFError, wave.Error):
        return None


def validate_corpus(path: Path, *, verify_audio: bool = False) -> dict[str, Any]:
    payload = read_json(path)
    if payload.get("schema_version") != "1.0":
        raise BenchmarkConfigError("corpus schema_version must be '1.0'")
    corpus = payload.get("corpus")
    if not isinstance(corpus, dict) or not str(corpus.get("id") or "").strip():
        raise BenchmarkConfigError("corpus.id is required")
    reference_policy = corpus.get("reference_policy")
    if reference_policy not in {"manual-golden", "performance-only"}:
        raise BenchmarkConfigError(
            "corpus.reference_policy must be 'manual-golden' or 'performance-only'"
        )
    samples = payload.get("samples")
    if not isinstance(samples, list) or not samples:
        raise BenchmarkConfigError("corpus must contain at least one sample")
    base = path.parent
    seen: set[str] = set()
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict):
            raise BenchmarkConfigError(f"samples[{index}] must be an object")
        sample_id = str(sample.get("id") or "")
        if not sample_id or sample_id in seen:
            raise BenchmarkConfigError(f"sample id is empty or duplicated: {sample_id!r}")
        seen.add(sample_id)
        audio = sample.get("audio")
        reference = sample.get("reference")
        if not isinstance(audio, dict) or not str(audio.get("path") or ""):
            raise BenchmarkConfigError(f"sample {sample_id}: audio.path is required")
        if reference_policy == "manual-golden":
            if not isinstance(reference, dict) or reference.get("status") != "golden":
                raise BenchmarkConfigError(f"sample {sample_id}: reference.status must be 'golden'")
            if not str(reference.get("path") or ""):
                raise BenchmarkConfigError(f"sample {sample_id}: reference.path is required")
        duration = float(audio.get("duration_seconds") or 0.0)
        if not math.isfinite(duration) or duration <= 0:
            raise BenchmarkConfigError(f"sample {sample_id}: positive audio.duration_seconds is required")
        if verify_audio:
            audio_path = resolve_path(base, str(audio["path"]))
            if not audio_path.is_file():
                raise BenchmarkConfigError(f"sample {sample_id}: audio not found: {audio_path}")
            expected_sha = str(audio.get("sha256") or "")
            if not expected_sha:
                raise BenchmarkConfigError(f"sample {sample_id}: audio.sha256 is required")
            actual_sha = sha256_file(audio_path)
            if actual_sha != expected_sha:
                raise BenchmarkConfigError(
                    f"sample {sample_id}: sha256 mismatch, expected {expected_sha}, got {actual_sha}"
                )
            measured = wav_duration(audio_path)
            if measured is not None and abs(measured - duration) > 0.1:
                raise BenchmarkConfigError(
                    f"sample {sample_id}: duration mismatch, expected {duration}, got {measured}"
                )
        if reference_policy == "manual-golden":
            reference_path = resolve_path(base, str(reference["path"]))
            if reference_path.is_file():
                validate_reference(read_json(reference_path), sample_id=sample_id)
            elif verify_audio:
                raise BenchmarkConfigError(f"sample {sample_id}: reference not found: {reference_path}")
    return payload


def validate_reference(payload: dict[str, Any], *, sample_id: str | None = None) -> None:
    label = sample_id or str(payload.get("sample_id") or "reference")
    if payload.get("schema_version") != "1.0":
        raise BenchmarkConfigError(f"{label}: reference schema_version must be '1.0'")
    if payload.get("annotation", {}).get("status") != "golden":
        raise BenchmarkConfigError(f"{label}: annotation.status must be 'golden'")
    if not str(payload.get("text") or "").strip():
        raise BenchmarkConfigError(f"{label}: non-empty text is required")
    words = payload.get("words")
    turns = payload.get("speaker_turns")
    if not isinstance(words, list) or not words:
        raise BenchmarkConfigError(f"{label}: manually timed words[] are required")
    if not isinstance(turns, list) or not turns:
        raise BenchmarkConfigError(f"{label}: speaker_turns[] are required")
    for collection_name, collection in (("words", words), ("speaker_turns", turns)):
        for index, item in enumerate(collection):
            if not isinstance(item, dict):
                raise BenchmarkConfigError(f"{label}: {collection_name}[{index}] must be an object")
            try:
                start = float(item["start"])
                end = float(item["end"])
            except (KeyError, TypeError, ValueError) as exc:
                raise BenchmarkConfigError(
                    f"{label}: {collection_name}[{index}] needs numeric start/end"
                ) from exc
            if not math.isfinite(start) or not math.isfinite(end) or end <= start:
                raise BenchmarkConfigError(f"{label}: invalid interval in {collection_name}[{index}]")
            if not str(item.get("speaker") or ""):
                raise BenchmarkConfigError(f"{label}: {collection_name}[{index}].speaker is required")
            if collection_name == "words" and not str(item.get("text") or "").strip():
                raise BenchmarkConfigError(f"{label}: words[{index}].text is required")


def validate_engines(path: Path) -> dict[str, Any]:
    payload = read_json(path)
    if payload.get("schema_version") != "1.0":
        raise BenchmarkConfigError("engine schema_version must be '1.0'")
    engines = payload.get("engines")
    if not isinstance(engines, list) or not engines:
        raise BenchmarkConfigError("engines[] must not be empty")
    seen: set[str] = set()
    for index, engine in enumerate(engines):
        if not isinstance(engine, dict):
            raise BenchmarkConfigError(f"engines[{index}] must be an object")
        engine_id = str(engine.get("id") or "")
        if not engine_id or engine_id in seen:
            raise BenchmarkConfigError(f"engine id is empty or duplicated: {engine_id!r}")
        seen.add(engine_id)
        if engine.get("kind") not in {"asr", "diarization", "pipeline"}:
            raise BenchmarkConfigError(f"engine {engine_id}: invalid kind")
        command = engine.get("command")
        if not isinstance(command, list) or not command or not all(isinstance(x, str) for x in command):
            raise BenchmarkConfigError(f"engine {engine_id}: command must be a non-empty string array")
        for required in ("version", "model", "model_revision", "license"):
            if not str(engine.get(required) or "").strip():
                raise BenchmarkConfigError(f"engine {engine_id}: {required} is required")
    return payload


def validate_prediction(payload: dict[str, Any], *, kind: str) -> None:
    if payload.get("schema_version") != "1.0":
        raise BenchmarkConfigError("prediction schema_version must be '1.0'")
    if kind in {"asr", "pipeline"} and not isinstance(payload.get("text"), str):
        raise BenchmarkConfigError("ASR prediction must contain text")
    if kind in {"diarization", "pipeline"} and not isinstance(payload.get("speaker_turns"), list):
        raise BenchmarkConfigError("diarization prediction must contain speaker_turns[]")
    for collection_name in ("segments", "words", "speaker_turns"):
        collection = payload.get(collection_name)
        if collection is None:
            continue
        if not isinstance(collection, list):
            raise BenchmarkConfigError(f"prediction {collection_name} must be an array")
        for item in collection:
            if not isinstance(item, dict):
                raise BenchmarkConfigError(f"prediction {collection_name} items must be objects")
            if "start" in item or "end" in item:
                start = float(item["start"])
                end = float(item["end"])
                if not math.isfinite(start) or not math.isfinite(end) or end < start:
                    raise BenchmarkConfigError(f"invalid prediction interval: {item!r}")
