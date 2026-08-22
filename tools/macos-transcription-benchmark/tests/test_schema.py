from __future__ import annotations

import json
import tempfile
import unittest
import wave
from pathlib import Path

from contora_benchmark.schema import (
    BenchmarkConfigError,
    prediction_semantic_sha256,
    sha256_file,
    validate_corpus,
    validate_prediction,
)


class SchemaTests(unittest.TestCase):
    def test_semantic_hash_ignores_timing_but_not_result_content(self):
        first = {"kind": "asr", "text": "да", "words": [], "timing": {"total": 1.0}}
        second = {"kind": "asr", "text": "да", "words": [], "timing": {"total": 2.0}}
        changed = {"kind": "asr", "text": "нет", "words": [], "timing": {"total": 1.0}}
        self.assertEqual(prediction_semantic_sha256(first), prediction_semantic_sha256(second))
        self.assertNotEqual(prediction_semantic_sha256(first), prediction_semantic_sha256(changed))

    def test_validates_audio_hash_duration_and_manual_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / "audio.wav"
            with wave.open(str(audio), "wb") as handle:
                handle.setnchannels(1)
                handle.setsampwidth(2)
                handle.setframerate(16000)
                handle.writeframes(b"\0\0" * 16000)
            reference = {
                "schema_version": "1.0",
                "sample_id": "sample",
                "annotation": {"status": "golden", "annotators": ["human"]},
                "text": "да",
                "words": [{"text": "да", "start": 0.1, "end": 0.4, "speaker": "A"}],
                "speaker_turns": [{"start": 0.1, "end": 0.4, "speaker": "A"}],
            }
            (root / "reference.json").write_text(json.dumps(reference), encoding="utf-8")
            manifest = {
                "schema_version": "1.0",
                "corpus": {"id": "test", "reference_policy": "manual-golden"},
                "samples": [
                    {
                        "id": "sample",
                        "audio": {"path": "audio.wav", "duration_seconds": 1.0, "sha256": sha256_file(audio)},
                        "reference": {"path": "reference.json", "status": "golden"},
                    }
                ],
            }
            manifest_path = root / "corpus.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertEqual(validate_corpus(manifest_path, verify_audio=True)["corpus"]["id"], "test")

    def test_rejects_asr_seed_marked_as_golden(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = {
                "schema_version": "1.0",
                "corpus": {"id": "test", "reference_policy": "manual-golden"},
                "samples": [
                    {
                        "id": "sample",
                        "audio": {"path": "missing.wav", "duration_seconds": 1.0},
                        "reference": {"path": "seed.json", "status": "asr-seed"},
                    }
                ],
            }
            path = root / "corpus.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaises(BenchmarkConfigError):
                validate_corpus(path)

    def test_prediction_rejects_non_finite_interval(self):
        with self.assertRaises(BenchmarkConfigError):
            validate_prediction(
                {
                    "schema_version": "1.0",
                    "text": "",
                    "speaker_turns": [{"start": 0.0, "end": float("nan"), "speaker": "A"}],
                },
                kind="diarization",
            )

    def test_performance_only_corpus_does_not_claim_golden_references(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / "audio.wav"
            with wave.open(str(audio), "wb") as handle:
                handle.setnchannels(1)
                handle.setsampwidth(2)
                handle.setframerate(16000)
                handle.writeframes(b"\0\0" * 16000)
            manifest = {
                "schema_version": "1.0",
                "corpus": {"id": "performance", "reference_policy": "performance-only"},
                "samples": [
                    {
                        "id": "sample",
                        "audio": {"path": "audio.wav", "duration_seconds": 1.0, "sha256": sha256_file(audio)},
                    }
                ],
            }
            path = root / "corpus.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertEqual(validate_corpus(path, verify_audio=True)["corpus"]["id"], "performance")


if __name__ == "__main__":
    unittest.main()
