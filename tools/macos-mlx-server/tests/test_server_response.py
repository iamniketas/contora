import io
import json
import math
import tempfile
import time
import unittest
import wave
from pathlib import Path
import sys
from unittest.mock import patch


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
                    "words": [
                        {
                            "word": " Привет",
                            "start": 0.0,
                            "end": 1.0,
                            "probability": math.nan,
                        }
                    ],
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
            server._job_telemetry.clear()

    def configure_roots(self, directory):
        server.RESULTS_ROOT = Path(directory) / "results"
        server.HANDOFF_ROOT = Path(directory) / "handoff"
        server.HARDWARE_PROFILE_PATH = Path(directory) / "hardware-profiles.json"
        server.RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
        server.HANDOFF_ROOT.mkdir(parents=True, exist_ok=True)

    def wav_bytes(self):
        output = io.BytesIO()
        with wave.open(output, "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(16_000)
            handle.writeframes(b"\x00\x00" * 1_600)
        return output.getvalue()

    def test_health_reports_only_nonterminal_jobs_as_active(self):
        with server._jobs_lock:
            server._jobs["running"] = {"state": "transcribing"}
            server._jobs["done"] = {"state": "completed"}
            server._jobs["failed"] = {"state": "failed"}
        self.assertEqual(server.health()["activeJobs"], 1)

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
            segment = payload["asr_segments"][0]
            self.assertIsNone(segment["avg_logprob"])
            self.assertIsNone(segment["diagnostics"]["positive_infinity"])
            self.assertIsNone(segment["diagnostics"]["negative_infinity"])
            self.assertEqual(payload["schema_version"], "2.0")
            self.assertEqual(payload["words"][0]["speaker"], "SPEAKER_00")
            self.assertIsNone(payload["words"][0]["confidence"])

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
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            original_model_for = server.model_for
            server.model_for = lambda _name: SlowFakeModel()
            with TestClient(server.app) as client:
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
            status_path = server.RESULTS_ROOT / job_id / "status.json"
            self.assertEqual(json.loads(status_path.read_text())["state"], "completed")
            self.assertEqual(list(status_path.parent.glob("*.tmp")), [])

            result = client.get(f"/v1/transcription/jobs/{job_id}/result")
            self.assertEqual(result.status_code, 200, result.text)
            self.assertEqual(result.content, (server.RESULTS_ROOT / job_id / "result.json").read_bytes())

    def test_job_api_cancel_marks_job_cancelled(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            original_model_for = server.model_for
            server.model_for = lambda _name: SlowFakeModel()
            with TestClient(server.app) as client:
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

    def test_file_handoff_is_capability_bound_and_persists_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            token = "a" * 32
            audio_path = server.HANDOFF_ROOT / f"{token}.wav"
            descriptor_path = server.HANDOFF_ROOT / f"{token}.json"
            audio_path.write_bytes(b"RIFF")
            descriptor_path.write_text(
                json.dumps(
                    {
                        "schema_version": "1.0",
                        "capability_token": token,
                        "audio_path": str(audio_path),
                        "created_at": time.time(),
                    }
                )
            )
            original_model_for = server.model_for
            server.model_for = lambda _name: FakeModel()
            with TestClient(server.app) as client:
                try:
                    creation = client.post(
                        "/v1/transcription/jobs/from-file",
                        json={
                            "capability_token": token,
                            "model": "test",
                            "language": "ru",
                            "diarize": False,
                        },
                    )
                    self.assertEqual(creation.status_code, 202, creation.text)
                    job_id = creation.json()["job_id"]
                    duplicate = client.post(
                        "/v1/transcription/jobs/from-file",
                        json={
                            "capability_token": token,
                            "model": "test",
                            "language": "ru",
                            "diarize": False,
                        },
                    )
                    self.assertEqual(duplicate.status_code, 400, duplicate.text)
                    for _ in range(100):
                        status = client.get(f"/v1/transcription/jobs/{job_id}").json()
                        if status["state"] == "completed":
                            break
                        time.sleep(0.01)
                finally:
                    server.model_for = original_model_for

            self.assertEqual(status["state"], "completed", status)
            manifest = json.loads((server.RESULTS_ROOT / job_id / "job.json").read_text())
            self.assertEqual(manifest["capability_token"], token)
            self.assertEqual(Path(manifest["audio_path"]), audio_path.resolve())
            self.assertFalse((server.RESULTS_ROOT / job_id / "input.wav").exists())
            self.assertFalse(descriptor_path.exists())
            self.assertTrue((server.RESULTS_ROOT / job_id / "capability.json").exists())

    def test_file_handoff_rejects_descriptor_for_another_path(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            token = "b" * 32
            outside = Path(directory) / "outside.wav"
            outside.write_bytes(b"RIFF")
            (server.HANDOFF_ROOT / f"{token}.json").write_text(
                json.dumps({"capability_token": token, "audio_path": str(outside)})
            )
            with TestClient(server.app) as client:
                response = client.post(
                    "/v1/transcription/jobs/from-file",
                    json={"capability_token": token, "model": "test", "diarize": False},
                )
            self.assertEqual(response.status_code, 400, response.text)

    def test_backend_restart_resumes_from_asr_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            job_id = "11111111-1111-4111-8111-111111111111"
            job_root = server.RESULTS_ROOT / job_id
            job_root.mkdir()
            audio_path = job_root / "input.wav"
            audio_path.write_bytes(b"RIFF")
            now = time.time()
            (job_root / "job.json").write_text(
                json.dumps(
                    {
                        "schema_version": "1.0",
                        "job_id": job_id,
                        "audio_path": str(audio_path),
                        "model": "test",
                        "language": "ru",
                        "diarize": False,
                        "chunk_duration": 30,
                        "created_at": now,
                    }
                )
            )
            (job_root / "status.json").write_text(
                json.dumps(
                    {
                        "schema_version": "1.0",
                        "job_id": job_id,
                        "state": "transcribing",
                        "phase": "transcribing",
                        "message": "Interrupted",
                        "progress": 0.5,
                        "created_at": now,
                        "updated_at": now,
                    }
                )
            )
            (job_root / "asr.json").write_text(
                json.dumps(
                    {
                        "schema_version": "2.0",
                        "job_id": job_id,
                        "model": "test",
                        "language": "ru",
                        "text": "Возобновлено",
                        "segments": [
                            {
                                "start": 0,
                                "end": 1,
                                "text": "Возобновлено",
                                "words": [
                                    {
                                        "word": " Возобновлено",
                                        "start": 0,
                                        "end": 1,
                                        "probability": 0.9,
                                    }
                                ],
                            }
                        ],
                        "word_timestamps": True,
                        "timing": {"asr": 2.0},
                    }
                )
            )
            original_model_for = server.model_for
            server.model_for = lambda _name: self.fail("ASR model must not load when checkpoint is reusable")
            with TestClient(server.app) as client:
                try:
                    for _ in range(100):
                        status = client.get(f"/v1/transcription/jobs/{job_id}").json()
                        if status["state"] == "completed":
                            break
                        time.sleep(0.01)
                finally:
                    server.model_for = original_model_for

            self.assertEqual(status["state"], "completed", status)
            result = json.loads((job_root / "result.json").read_text())
            self.assertEqual(result["raw_text"], "Возобновлено")

    def test_ttl_cleanup_removes_delivered_job_and_owned_handoff(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            token = "c" * 32
            audio_path = server.HANDOFF_ROOT / f"{token}.wav"
            descriptor_path = server.HANDOFF_ROOT / f"{token}.json"
            audio_path.write_bytes(b"RIFF")
            descriptor_path.write_text("{}")
            job_id = "22222222-2222-4222-8222-222222222222"
            job_root = server.RESULTS_ROOT / job_id
            job_root.mkdir()
            (job_root / "job.json").write_text(
                json.dumps({"job_id": job_id, "capability_token": token, "audio_path": str(audio_path)})
            )
            (job_root / "status.json").write_text(
                json.dumps(
                    {
                        "job_id": job_id,
                        "state": "completed",
                        "updated_at": 10.0,
                        "result_delivered_at": 10.0,
                    }
                )
            )
            original_ttl = server.JOB_TTL_SECONDS
            server.JOB_TTL_SECONDS = 60
            try:
                removed = server._cleanup_expired_jobs(now=71.0)
            finally:
                server.JOB_TTL_SECONDS = original_ttl

            self.assertEqual(removed, [job_id])
            self.assertFalse(job_root.exists())
            self.assertFalse(audio_path.exists())
            self.assertFalse(descriptor_path.exists())

    def test_rolling_rate_waits_for_stable_window_and_uses_robust_rate(self):
        estimator = server.RollingRateEstimator(minimum_samples=3, minimum_span=1.0)
        self.assertIsNone(estimator.observe(0, now=0)["rate"])
        self.assertIsNone(estimator.observe(10, now=0.5)["rate"])
        stable = estimator.observe(20, now=1.0)
        self.assertEqual(stable["rate"], 20.0)
        after_outlier = estimator.observe(21, now=2.0)
        self.assertAlmostEqual(after_outlier["rate"], 20.0)

    def test_hardware_profile_uses_duration_normalized_stage_weights(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            server._store_hardware_profile(
                "test",
                True,
                asr_seconds=50,
                diarization_seconds=40,
                merge_seconds=10,
                audio_seconds=100,
            )
            asr, diarization, merge = server._stage_weights("test", True)

            self.assertAlmostEqual(asr, 0.475)
            self.assertAlmostEqual(diarization, 0.38)
            self.assertAlmostEqual(merge, 0.095)
            self.assertAlmostEqual(asr + diarization + merge, 0.95)

    def test_hardware_profile_failure_cannot_invalidate_completed_result(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            original_model_for = server.model_for
            original_store_profile = server._store_hardware_profile

            def fail_profile_write(*_args, **_kwargs):
                raise OSError("profile disk unavailable")

            server.model_for = lambda _name: FakeModel()
            server._store_hardware_profile = fail_profile_write
            try:
                response = TestClient(server.app).post(
                    "/v1/audio/transcriptions",
                    files={"file": ("audio.wav", self.wav_bytes(), "audio/wav")},
                    data={"model": "test", "language": "ru", "diarize": "false"},
                )
            finally:
                server.model_for = original_model_for
                server._store_hardware_profile = original_store_profile

            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual(response.json()["text"].split(": ")[-1], "Привет")

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

    def test_word_attribution_splits_speaker_change_inside_one_asr_segment(self):
        segments = [
            {
                "start": 0.0,
                "end": 1.0,
                "text": "Первый Второй",
                "words": [
                    {"word": " Первый", "start": 0.0, "end": 0.45, "probability": 0.9},
                    {"word": " Второй", "start": 0.55, "end": 1.0, "probability": 0.8},
                ],
            }
        ]
        turns = [
            {"start": 0.0, "end": 0.5, "speaker": "SPEAKER_00", "confidence": None},
            {"start": 0.5, "end": 1.0, "speaker": "SPEAKER_01", "confidence": None},
        ]

        words = server.attribute_speakers_to_words(server.extract_asr_words(segments), turns)
        utterances = server.assemble_utterances(words)

        self.assertEqual([word["speaker"] for word in words], ["SPEAKER_00", "SPEAKER_01"])
        self.assertEqual([item["speaker"] for item in utterances], ["SPEAKER_00", "SPEAKER_01"])
        self.assertEqual([item["text"] for item in utterances], ["Первый", "Второй"])

    def test_word_attribution_marks_true_overlapping_speech(self):
        words = [{"text": " вместе", "start": 0.5, "end": 0.7, "confidence": 0.9}]
        turns = [
            {"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00", "confidence": None},
            {"start": 0.4, "end": 0.8, "speaker": "SPEAKER_01", "confidence": None},
        ]

        attributed = server.attribute_speakers_to_words(words, turns)

        self.assertTrue(attributed[0]["overlap"])
        self.assertEqual(attributed[0]["overlap_speakers"], ["SPEAKER_00", "SPEAKER_01"])
        self.assertEqual(attributed[0]["speaker"], "SPEAKER_00")

    def test_schema_v2_requests_native_whisper_word_timestamps(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)

            class CapturingModel(FakeModel):
                kwargs = None

                def generate(self, *_args, **kwargs):
                    self.kwargs = kwargs
                    return super().generate(*_args, **kwargs)

            model = CapturingModel()
            original_model_for = server.model_for
            server.model_for = lambda _name: model
            try:
                response = TestClient(server.app).post(
                    "/v1/audio/transcriptions",
                    files={"file": ("audio.wav", self.wav_bytes(), "audio/wav")},
                    data={"model": "test", "language": "ru", "diarize": "false"},
                )
            finally:
                server.model_for = original_model_for

            self.assertEqual(response.status_code, 200, response.text)
            self.assertIs(model.kwargs["word_timestamps"], True)

    def test_parallel_ane_gate_requires_assets_and_safe_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "contora-fluid-diarize"
            binary.write_text("binary")
            binary.chmod(0o755)
            models = root / "models"
            marker = models / "speaker-diarization-coreml/.contora-model-revision"
            marker.parent.mkdir(parents=True)
            marker.write_text(server.FLUID_MODEL_REVISION)
            original_binary = server.FLUID_BINARY
            original_models = server.FLUID_MODELS_ROOT
            server.FLUID_BINARY = binary
            server.FLUID_MODELS_ROOT = models
            try:
                with patch.dict(
                    server.os.environ,
                    {
                        "CONTORA_MLX_ENABLE_EXPERIMENTAL_ANE": "1",
                        "CONTORA_MLX_ENABLE_PARALLEL_ANE": "1",
                    },
                    clear=False,
                ):
                    enabled = server.parallel_ane_decision(
                        diarize=True,
                        snapshot={
                            "memory_free_percent": 50,
                            "swap_used_bytes": 0,
                            "thermal_warning": False,
                        },
                    )
                    pressured = server.parallel_ane_decision(
                        diarize=True,
                        snapshot={
                            "memory_free_percent": 50,
                            "swap_used_bytes": 5 * 1024**3,
                            "thermal_warning": False,
                        },
                    )
                    thermal = server.parallel_ane_decision(
                        diarize=True,
                        snapshot={
                            "memory_free_percent": 50,
                            "swap_used_bytes": 0,
                            "thermal_warning": True,
                        },
                    )
            finally:
                server.FLUID_BINARY = original_binary
                server.FLUID_MODELS_ROOT = original_models

            self.assertEqual(enabled, (True, "ane-quality-gate-enabled"))
            self.assertEqual(pressured, (False, "swap-pressure"))
            self.assertEqual(thermal, (False, "thermal-warning"))

    def test_parallel_ane_failure_falls_back_to_sequential_pyannote(self):
        class FakeDiarization:
            def itertracks(self, yield_label=False):
                return iter([])

        class FakePipeline:
            def __call__(self, _audio_path, hook=None):
                if hook is not None:
                    hook("segmentation", None, total=1, completed=1)
                return FakeDiarization()

        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            original_model_for = server.model_for
            original_pipeline = server.diarization_pipeline
            original_decision = server.parallel_ane_decision
            original_fluid = server.run_fluid_diarization

            def fail_fluid(*_args, **_kwargs):
                raise RuntimeError("ANE failed")

            server.model_for = lambda _name: FakeModel()
            server.diarization_pipeline = lambda: FakePipeline()
            server.parallel_ane_decision = lambda **_kwargs: (True, "test-enabled")
            server.run_fluid_diarization = fail_fluid
            try:
                response = TestClient(server.app).post(
                    "/v1/audio/transcriptions",
                    files={"file": ("audio.wav", self.wav_bytes(), "audio/wav")},
                    data={"model": "test", "language": "ru", "diarize": "true"},
                )
            finally:
                server.model_for = original_model_for
                server.diarization_pipeline = original_pipeline
                server.parallel_ane_decision = original_decision
                server.run_fluid_diarization = original_fluid

            self.assertEqual(response.status_code, 200, response.text)
            payload = response.json()
            self.assertEqual(payload["backend"], "mlx+pyannote")
            status = json.loads((server.RESULTS_ROOT / payload["job_id"] / "status.json").read_text())
            self.assertEqual(status["execution_mode"], "sequential_fallback")

    def test_parallel_ane_success_is_recorded_without_loading_pyannote(self):
        with tempfile.TemporaryDirectory() as directory:
            self.configure_roots(directory)
            original_model_for = server.model_for
            original_pipeline = server.diarization_pipeline
            original_decision = server.parallel_ane_decision
            original_fluid = server.run_fluid_diarization
            server.model_for = lambda _name: FakeModel()
            server.diarization_pipeline = lambda: self.fail("pyannote fallback must not load")
            server.parallel_ane_decision = lambda **_kwargs: (True, "test-enabled")
            server.run_fluid_diarization = lambda *_args, **_kwargs: [
                {
                    "start": 0.0,
                    "end": 1.0,
                    "speaker": "speaker_0",
                    "confidence": 0.9,
                }
            ]
            try:
                response = TestClient(server.app).post(
                    "/v1/audio/transcriptions",
                    files={"file": ("audio.wav", self.wav_bytes(), "audio/wav")},
                    data={"model": "test", "language": "ru", "diarize": "true"},
                )
            finally:
                server.model_for = original_model_for
                server.diarization_pipeline = original_pipeline
                server.parallel_ane_decision = original_decision
                server.run_fluid_diarization = original_fluid

            self.assertEqual(response.status_code, 200, response.text)
            payload = response.json()
            self.assertEqual(payload["backend"], "mlx+fluidaudio")
            self.assertEqual(payload["words"][0]["speaker"], "speaker_0")
            self.assertEqual(payload["parameters"]["execution_mode"], "parallel_ane")


if __name__ == "__main__":
    unittest.main()
