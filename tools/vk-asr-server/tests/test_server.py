from __future__ import annotations

import json
import struct
import time
from pathlib import Path

from fastapi.testclient import TestClient

import contora_vk_server.server as server


def test_file_handoff_job_contract(tmp_path: Path, monkeypatch) -> None:
    handoff_root = tmp_path / "handoff"
    results_root = tmp_path / "results"
    handoff_root.mkdir()
    token = "0123456789abcdef0123456789abcdef"
    audio_path = handoff_root / f"{token}.wav"
    descriptor_path = handoff_root / f"{token}.json"
    # Minimal 1-second, 16 kHz, mono float32 WAV so duration is available
    # immediately after the capability handoff.
    sample_count = 16_000
    data_size = sample_count * 4
    audio_path.write_bytes(
        b"RIFF"
        + struct.pack("<I", 36 + data_size)
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 3, 1, 16_000, 64_000, 4, 32)
        + b"data"
        + struct.pack("<I", data_size)
        + (b"\0" * data_size)
    )
    descriptor_path.write_text(
        json.dumps(
            {
                "schema_version": "1.0",
                "capability_token": token,
                "audio_path": str(audio_path),
                "created_at": time.time(),
            }
        ),
        encoding="utf-8",
    )

    monkeypatch.setattr(server, "HANDOFF_ROOT", handoff_root)
    monkeypatch.setattr(server, "RESULTS_ROOT", results_root)
    monkeypatch.setattr(server, "_jobs", {})
    monkeypatch.setattr(server, "_cancellations", {})

    def fake_pipeline(source_audio: Path, job_id: str, output_root: Path, **kwargs):
        del source_audio, output_root, kwargs
        return {
            "schema_version": "2.0",
            "job_id": job_id,
            "text": "[00:00:00.000 --> 00:00:01.000] [SPEAKER_00]: Тест",
            "raw_text": "Тест",
            "words": [],
            "speaker_turns": [],
            "utterances": [],
            "asr_segments": [],
            "segments": [],
            "language": "ru-observed-not-declared",
            "backend": "test",
            "model": "latest",
            "timing": {"total": 0.01, "asr": 0.01, "diarization": 0.0, "merge": 0.0},
        }

    monkeypatch.setattr(server, "run_pipeline", fake_pipeline)
    client = TestClient(server.app)
    created = client.post(
        "/v1/transcription/jobs/from-file",
        json={"capability_token": token, "model": "ignored", "diarize": True},
    )
    assert created.status_code == 202
    job_id = created.json()["job_id"]
    assert created.json()["total_seconds"] == 1.0
    assert not descriptor_path.exists()
    assert not audio_path.exists()

    deadline = time.monotonic() + 2
    status = created.json()
    while status["state"] != "completed" and time.monotonic() < deadline:
        status = client.get(f"/v1/transcription/jobs/{job_id}").json()
        time.sleep(0.01)
    assert status["state"] == "completed"
    result = client.get(f"/v1/transcription/jobs/{job_id}/result")
    assert result.status_code == 200
    assert result.json()["schema_version"] == "2.0"
    assert result.json()["job_id"] == job_id


def test_ready_rejects_missing_token(monkeypatch) -> None:
    monkeypatch.setenv("SPEECH_API_BASE_URL", "http://speech.invalid")
    monkeypatch.setenv("CONTORA_VK_UPLOAD_BASE_URL", "https://upload.invalid")
    monkeypatch.delenv("SPEECH_API_TOKEN", raising=False)
    response = TestClient(server.app).get("/ready")
    assert response.status_code == 503
    assert "SPEECH_API_TOKEN" in response.json()["message"]


def test_ready_accepts_complete_configuration(monkeypatch) -> None:
    monkeypatch.setenv("SPEECH_API_BASE_URL", "http://speech.invalid")
    monkeypatch.setenv("CONTORA_VK_UPLOAD_BASE_URL", "https://upload.invalid")
    monkeypatch.setenv("SPEECH_API_TOKEN", "secret-test-value")
    response = TestClient(server.app).get("/ready")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["tokenConfigured"] is True
