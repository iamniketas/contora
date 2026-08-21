import json
import math
import tempfile
import time
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


class SlowFakeModel(FakeModel):
    def generate(self, *_args, **_kwargs):
        time.sleep(0.15)
        return super().generate(*_args, **_kwargs)


class ServerResponseTests(unittest.TestCase):
    def setUp(self):
        with server._jobs_lock:
            server._jobs.clear()
            server._job_tasks.clear()
            server._job_cancellations.clear()

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

    def test_job_api_polls_persisted_monotonic_status_and_result(self):
        with tempfile.TemporaryDirectory() as directory, TestClient(server.app) as client:
            server.RESULTS_ROOT = Path(directory)
            original_model_for = server.model_for
            server.model_for = lambda _name: SlowFakeModel()
            try:
                creation = client.post(
                    "/v1/transcription/jobs",
                    files={"file": ("audio.wav", b"RIFF", "audio/wav")},
                    data={"model": "test", "language": "ru", "diarize": "false"},
                )
                self.assertEqual(creation.status_code, 202, creation.text)
                job_id = creation.json()["job_id"]
                statuses = [creation.json()]
                for _ in range(100):
                    status_response = client.get(f"/v1/transcription/jobs/{job_id}")
                    self.assertEqual(status_response.status_code, 200, status_response.text)
                    status = status_response.json()
                    statuses.append(status)
                    if status["state"] in {"completed", "failed", "cancelled"}:
                        break
                    time.sleep(0.01)
            finally:
                server.model_for = original_model_for

            self.assertEqual(statuses[-1]["state"], "completed", statuses[-1])
            progress = [status["progress"] for status in statuses]
            self.assertEqual(progress, sorted(progress))
            self.assertEqual(progress[-1], 1.0)
            self.assertTrue(any(status["phase"] == "transcribing" for status in statuses))
            status_path = Path(directory) / job_id / "status.json"
            self.assertEqual(json.loads(status_path.read_text())["state"], "completed")
            self.assertEqual(list(status_path.parent.glob("*.tmp")), [])

            result = client.get(f"/v1/transcription/jobs/{job_id}/result")
            self.assertEqual(result.status_code, 200, result.text)
            self.assertEqual(result.content, (Path(directory) / job_id / "result.json").read_bytes())

    def test_job_api_cancel_marks_job_cancelled(self):
        with tempfile.TemporaryDirectory() as directory, TestClient(server.app) as client:
            server.RESULTS_ROOT = Path(directory)
            original_model_for = server.model_for
            server.model_for = lambda _name: SlowFakeModel()
            try:
                creation = client.post(
                    "/v1/transcription/jobs",
                    files={"file": ("audio.wav", b"RIFF", "audio/wav")},
                    data={"model": "test", "language": "ru", "diarize": "false"},
                )
                job_id = creation.json()["job_id"]
                cancellation = client.delete(f"/v1/transcription/jobs/{job_id}")
                self.assertEqual(cancellation.status_code, 202, cancellation.text)
                for _ in range(100):
                    status = client.get(f"/v1/transcription/jobs/{job_id}").json()
                    if status["state"] == "cancelled":
                        break
                    time.sleep(0.01)
            finally:
                server.model_for = original_model_for

            self.assertEqual(status["state"], "cancelled", status)

    def test_mlx_internal_seek_progress_callback_is_monotonic(self):
        from mlx_audio.stt.models.whisper import whisper as whisper_module

        observed = []
        with server.mlx_progress_callback(observed.append):
            with whisper_module.tqdm.tqdm(total=100, disable=True) as progress:
                progress.update(25)
                progress.update(50)
                progress.update(25)

        self.assertEqual(observed, [0.0, 0.25, 0.75, 1.0])

    def test_diarization_hook_reports_monotonic_pipeline_progress(self):
        class FakeDiarization:
            def itertracks(self, yield_label=False):
                return iter([])

        class FakePipeline:
            def __call__(self, _audio_path, hook=None):
                hook("segmentation", None, total=10, completed=0)
                hook("segmentation", None, total=10, completed=10)
                hook("embeddings", None, total=2, completed=1)
                hook("embeddings", None, total=2, completed=2)
                hook("discrete_diarization", None)
                return FakeDiarization()

        original_pipeline = server.diarization_pipeline
        server.diarization_pipeline = lambda: FakePipeline()
        observed = []
        try:
            server.assign_speakers(
                "audio.wav",
                [{"start": 0.0, "end": 1.0, "text": "test"}],
                progress_callback=lambda fraction, step: observed.append((fraction, step)),
            )
        finally:
            server.diarization_pipeline = original_pipeline

        fractions = [fraction for fraction, _ in observed]
        self.assertEqual(fractions, sorted(fractions))
        self.assertEqual(fractions[-1], 1.0)


if __name__ == "__main__":
    unittest.main()
