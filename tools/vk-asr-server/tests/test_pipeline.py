from __future__ import annotations

import threading
from pathlib import Path

import pytest

from contora_vk_server.pipeline import (
    PipelineConfig,
    assemble_utterances,
    attribute_speakers,
    consolidate_speaker_turns,
    normalize_asr_segments,
    recognize_long_audio,
    recognition_quality,
    run_pipeline,
)


def test_normalize_asr_segments_accepts_string_and_number_milliseconds() -> None:
    segments = normalize_asr_segments(
        {
            "confidence": 0.91,
            "segments": [
                {"startTimeMs": "1200", "endTimeMs": 4380, "text": "Первый сегмент"},
            ],
        }
    )
    assert segments == [
        {
            "text": "Первый сегмент",
            "start": 1.2,
            "end": 4.38,
            "confidence": 0.91,
            "asr_segment_index": 0,
        }
    ]


def test_attribute_speakers_keeps_label_for_near_tie_and_marks_ambiguity() -> None:
    words = [{"text": "Спорная реплика", "start": 0.0, "end": 2.0, "confidence": None}]
    turns = [
        {"start": 0.0, "end": 1.05, "speaker": "SPEAKER_00"},
        {"start": 0.95, "end": 2.0, "speaker": "SPEAKER_01"},
    ]
    result = attribute_speakers(words, turns)
    assert result[0]["speaker"] == "SPEAKER_00"
    assert result[0]["overlap"] is True
    assert result[0]["overlap_speakers"] == ["SPEAKER_00", "SPEAKER_01"]


def test_attribute_speakers_keeps_uncovered_segment_unknown() -> None:
    words = [{"text": "Нет пересечения", "start": 10.0, "end": 11.0, "confidence": None}]
    result = attribute_speakers(words, [])
    assert result[0]["speaker"] == "UNKNOWN"
    assert result[0]["speaker_score"] == 0.0


def test_attribute_speakers_fills_short_vad_gap_from_nearest_turn() -> None:
    words = [{"text": "На границе", "start": 1.08, "end": 1.16, "confidence": None}]
    turns = [
        {"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"},
        {"start": 1.25, "end": 2.0, "speaker": "SPEAKER_01"},
    ]
    result = attribute_speakers(words, turns)
    assert result[0]["speaker"] == "SPEAKER_00"
    assert result[0]["speaker_score"] == 0.0


def test_consolidate_speaker_turns_preserves_dominant_clusters() -> None:
    turns = [
        {"start": 0.0, "end": 10.0, "speaker": "A"},
        {"start": 10.0, "end": 20.0, "speaker": "B"},
        {"start": 2.0, "end": 2.5, "speaker": "OUTLIER"},
    ]
    result = consolidate_speaker_turns(turns, 2)
    assert {turn["speaker"] for turn in result} == {"A", "B"}
    assert result[1]["speaker"] == "A"


def test_assemble_utterances_merges_adjacent_segments_for_same_speaker() -> None:
    words = [
        {
            "text": "Первая фраза.",
            "start": 0.0,
            "end": 1.0,
            "speaker": "SPEAKER_00",
            "overlap": False,
        },
        {
            "text": "Вторая фраза.",
            "start": 1.2,
            "end": 2.0,
            "speaker": "SPEAKER_00",
            "overlap": False,
        },
    ]
    utterances = assemble_utterances(words)
    assert len(utterances) == 1
    assert utterances[0]["text"] == "Первая фраза. Вторая фраза."
    assert utterances[0]["word_start_index"] == 0
    assert utterances[0]["word_end_index"] == 2


def test_recognition_quality_flags_zero_effective_duration() -> None:
    quality = recognition_quality(
        {"metadata": {"effectiveDurationMs": "0"}},
        [{"start": 0.0, "end": 2.0}],
    )
    assert quality["status"] == "incomplete"
    assert "effectiveDurationMs is zero" in quality["warnings"]


def test_recognition_quality_accepts_zero_effective_duration_with_full_segment_coverage() -> None:
    quality = recognition_quality(
        {"metadata": {"totalDurationMs": "2000", "effectiveDurationMs": "0"}},
        [{"start": 0.0, "end": 1.98}],
    )
    assert quality["status"] == "complete"
    assert quality["segment_coverage_ratio"] == pytest.approx(0.99)


class _Response:
    def __init__(self, payload: dict, status_code: int = 200):
        self._payload = payload
        self.status_code = status_code

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise AssertionError(f"unexpected HTTP {self.status_code}")

    def json(self) -> dict:
        return self._payload


def _config() -> PipelineConfig:
    return PipelineConfig(
        speech_base_url="http://speech.invalid",
        speech_token="secret",
        speech_model="latest",
        upload_base_url="https://upload.invalid",
        upload_max_days=1,
        connect_timeout_seconds=1,
        read_timeout_seconds=1,
        poll_interval_seconds=0,
        operation_timeout_seconds=10,
        runtime_root=Path("/unused"),
        diarization_device="cpu",
    )


def test_long_running_recognition_polls_only_by_operation_id(monkeypatch: pytest.MonkeyPatch) -> None:
    observed: dict[str, object] = {}

    def fake_post(url: str, **kwargs: object) -> _Response:
        observed["post_url"] = url
        observed["payload"] = kwargs["json"]
        return _Response({"operationId": "operation-1"})

    def fake_get(url: str, **kwargs: object) -> _Response:
        observed["poll_url"] = url
        observed["params"] = kwargs["params"]
        return _Response(
            {
                "status": "DONE",
                "response": {
                    "transcript": "Готово",
                    "segments": [{"startTimeMs": "0", "endTimeMs": "1000", "text": "Готово"}],
                },
            }
        )

    monkeypatch.setattr("contora_vk_server.pipeline.requests.post", fake_post)
    monkeypatch.setattr("contora_vk_server.pipeline.requests.get", fake_get)
    response, operation = recognize_long_audio(
        "https://upload.invalid/audio.mp3",
        _config(),
        threading.Event(),
        lambda _: None,
        1.0,
    )
    assert response["transcript"] == "Готово"
    assert operation["operation_id"] == "operation-1"
    assert observed["params"] == {"operationId": "operation-1"}
    assert "correlationId" not in observed["params"]
    assert observed["payload"]["audio"] == {"uri": "https://upload.invalid/audio.mp3"}


def test_pipeline_publishes_contora_result_v2(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    source = tmp_path / "input.wav"
    source.write_bytes(b"test-audio")

    def fake_prepare(_source: Path, destination: Path) -> None:
        destination.write_bytes(b"canonical-audio")

    monkeypatch.setattr("contora_vk_server.pipeline.prepare_canonical_audio", fake_prepare)
    monkeypatch.setattr(
        "contora_vk_server.pipeline.upload_transfer",
        lambda *args, **kwargs: "https://upload.invalid/private.mp3?signature=secret",
    )
    monkeypatch.setattr(
        "contora_vk_server.pipeline.recognize_long_audio",
        lambda *args, **kwargs: (
            {
                "transcript": "Тестовая реплика",
                "confidence": "0.95",
                "segments": [
                    {"startTimeMs": "0", "endTimeMs": "1000", "text": "Тестовая реплика"}
                ],
                "metadata": {"effectiveDurationMs": "1000"},
            },
            {"operation_id": "op-1", "correlation_id": "corr-1", "status_history": []},
        ),
    )

    def fake_diarizer(*args, **kwargs):
        return [{"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00", "confidence": None}]

    result = run_pipeline(
        source,
        "job-1",
        tmp_path / "results",
        enable_diarization=True,
        cancel=threading.Event(),
        config=_config(),
        diarizer=fake_diarizer,
    )
    assert result["schema_version"] == "2.0"
    assert result["backend"] == "corporate-asr+local-pyannote"
    assert result["words"][0]["speaker"] == "SPEAKER_00"
    assert result["words"][0]["confidence"] == 0.95
    assert result["quality"]["status"] == "complete"

    diagnostics = (tmp_path / "results/job-1/diagnostics.json").read_text(encoding="utf-8")
    assert "signature=secret" not in diagnostics
    assert "https://upload.invalid/private.mp3" in diagnostics
