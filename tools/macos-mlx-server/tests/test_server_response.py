import math
import tempfile
import unittest
from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import contora_mlx_server as server
    from fastapi.testclient import TestClient
except (ImportError, ModuleNotFoundError) as exc:  # The lightweight repo Python has no ML runtime.
    raise unittest.SkipTest(f"MLX server dependencies are unavailable: {exc}")


class FakeModel:
    def generate(self, *_args, **_kwargs):
        return {
            "text": "Привет",
            "language": "ru",
            "segments": [
                {
                    "start": 0.0,
                    "end": 1.0,
                    "text": "Привет",
                    "avg_logprob": math.nan,
                    "diagnostics": {
                        "positive_infinity": math.inf,
                        "negative_infinity": -math.inf,
                    },
                }
            ],
        }


class InvalidModel:
    def generate(self, *_args, **_kwargs):
        return {
            "text": "invalid segment",
            "language": "ru",
            "segments": [{"start": 0.0, "end": 1.0, "text": 42}],
        }


class ServerResponseTests(unittest.TestCase):
    def test_persists_sanitized_result_before_returning_it(self):
        with tempfile.TemporaryDirectory() as directory:
            server.RESULTS_ROOT = Path(directory)
            original_model_for = server.model_for
            server.model_for = lambda _name: FakeModel()
            try:
                response = TestClient(server.app).post(
                    "/v1/audio/transcriptions",
                    files={"file": ("audio.wav", b"RIFF", "audio/wav")},
                    data={"model": "test", "language": "ru", "diarize": "false"},
                )
            finally:
                server.model_for = original_model_for

            self.assertEqual(response.status_code, 200, response.text)
            payload = response.json()
            segment = payload["segments"][0]
            self.assertIsNone(segment["avg_logprob"])
            self.assertIsNone(segment["diagnostics"]["positive_infinity"])
            self.assertIsNone(segment["diagnostics"]["negative_infinity"])

            job_root = Path(directory) / payload["job_id"]
            self.assertTrue((job_root / "asr.json").exists())
            self.assertTrue((job_root / "diarization.json").exists())
            self.assertEqual((job_root / "result.json").read_bytes(), response.content)

    def test_returns_structured_recoverable_failure_after_asr_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            server.RESULTS_ROOT = Path(directory)
            original_model_for = server.model_for
            server.model_for = lambda _name: InvalidModel()
            try:
                response = TestClient(server.app).post(
                    "/v1/audio/transcriptions",
                    files={"file": ("audio.wav", b"RIFF", "audio/wav")},
                    data={"model": "test", "language": "ru", "diarize": "false"},
                )
            finally:
                server.model_for = original_model_for

            self.assertEqual(response.status_code, 500, response.text)
            payload = response.json()
            self.assertEqual(payload["state"], "failed")
            self.assertEqual(payload["error"]["stage"], "serializing")
            self.assertTrue(payload["error"]["recoverable"])
            job_root = Path(directory) / payload["job_id"]
            self.assertTrue((job_root / "asr.json").exists())
            self.assertTrue((job_root / "failure.json").exists())
            self.assertFalse((job_root / "result.json").exists())


if __name__ == "__main__":
    unittest.main()
