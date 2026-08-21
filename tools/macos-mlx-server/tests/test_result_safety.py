import json
import math
import tempfile
import unittest
from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from result_safety import (  # noqa: E402
    ResponseValidationError,
    atomic_write_json,
    sanitize_finite_numbers,
    strict_json_bytes,
    validate_transcription_response,
)


class ResultSafetyTests(unittest.TestCase):
    def test_sanitizes_non_finite_numbers_at_every_nesting_level(self):
        payload = {
            "nan": math.nan,
            "list": [1.0, math.inf, {"negative": -math.inf}],
            "tuple": (math.nan,),
        }

        sanitized = sanitize_finite_numbers(payload)

        self.assertIsNone(sanitized["nan"])
        self.assertIsNone(sanitized["list"][1])
        self.assertIsNone(sanitized["list"][2]["negative"])
        self.assertIsNone(sanitized["tuple"][0])
        encoded = strict_json_bytes(payload)
        self.assertNotIn(b"NaN", encoded)
        self.assertNotIn(b"Infinity", encoded)
        self.assertEqual(json.loads(encoded)["list"][1], None)

    def test_normalizes_array_like_diagnostics(self):
        class ArrayLike:
            def tolist(self):
                return [1.0, math.nan, math.inf, -math.inf]

        sanitized = sanitize_finite_numbers({"values": ArrayLike()})

        self.assertEqual(sanitized, {"values": [1.0, None, None, None]})

    def test_atomic_write_publishes_strict_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested" / "result.json"
            atomic_write_json(path, {"value": math.nan, "ok": 1.0})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"value": None, "ok": 1.0})
            self.assertEqual(list(path.parent.glob("*.tmp")), [])

    def test_validates_response_schema_after_sanitizing_diagnostics(self):
        payload = sanitize_finite_numbers(
            {
                "schema_version": "1.0",
                "job_id": "job-1",
                "text": "text",
                "raw_text": "text",
                "segments": [
                    {
                        "start": 0.0,
                        "end": 1.0,
                        "text": "text",
                        "speaker": "SPEAKER_00",
                        "avg_logprob": math.nan,
                        "nested": {"no_speech_prob": math.inf},
                    }
                ],
                "language": "ru",
                "backend": "mlx+pyannote",
                "model": "test",
                "timing": {"total": 3.0, "asr": 2.0, "diarization": 1.0},
            }
        )

        validated = validate_transcription_response(payload)

        self.assertIsNone(validated["segments"][0]["avg_logprob"])
        self.assertIsNone(validated["segments"][0]["nested"]["no_speech_prob"])

    def test_rejects_invalid_required_field(self):
        with self.assertRaises(ResponseValidationError):
            validate_transcription_response({"schema_version": "1.0"})


if __name__ == "__main__":
    unittest.main()
