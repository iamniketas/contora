from __future__ import annotations

import os
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

from contora_benchmark.runner import (
    ProcessMonitor,
    _expand_command,
    power_snapshot,
    run_benchmark,
    validate_power_for_benchmark,
)
from contora_benchmark.schema import BenchmarkConfigError


class RunnerTests(unittest.TestCase):
    def test_resource_abort_stops_all_remaining_repetitions(self):
        corpus = {
            "corpus": {"id": "test", "revision": "1"},
            "samples": [{"id": "sample", "audio": {"path": "audio.wav", "duration_seconds": 1}}],
        }
        engines = {"engines": [{"id": "engine"}]}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch(
                "contora_benchmark.runner._run_one",
                return_value={"state": "failed", "resource_aborted": True},
            ) as run_one, patch(
                "contora_benchmark.runner.hardware_profile", return_value={}
            ):
                result = run_benchmark(
                    corpus=corpus,
                    corpus_path=root / "corpus.json",
                    engines=engines,
                    engines_path=root / "engines.json",
                    output_root=root / "results",
                    repetitions=3,
                )
            self.assertEqual(run_one.call_count, 1)
            self.assertTrue(result["safety_aborted"])

    def test_power_preflight_requires_ac_and_minimum_charge(self):
        with patch(
            "contora_benchmark.runner._command_output",
            return_value="Now drawing from 'AC Power'\n -InternalBattery-0\t23%; charging;",
        ):
            self.assertEqual(validate_power_for_benchmark()["battery_percent"], 23)
        with patch(
            "contora_benchmark.runner._command_output",
            return_value="Now drawing from 'Battery Power'\n -InternalBattery-0\t80%; discharging;",
        ):
            self.assertFalse(power_snapshot()["charging"])
            with self.assertRaisesRegex(BenchmarkConfigError, "requires AC power"):
                validate_power_for_benchmark()
        with patch(
            "contora_benchmark.runner._command_output",
            return_value="Now drawing from 'AC Power'\n -InternalBattery-0\t5%; charging;",
        ):
            with self.assertRaisesRegex(BenchmarkConfigError, "at least 20%"):
                validate_power_for_benchmark()

    def test_monitor_requests_abort_after_excessive_swap_growth(self):
        monitor = ProcessMonitor(1, maximum_swap_growth_bytes=100)
        monitor.samples = [
            {
                "timestamp": 1.0,
                "process_tree_rss_bytes": 1,
                "swap_used_bytes": 1000,
                "memory_free_percent": 50,
                "thermal": [],
            }
        ]
        with ExitStack() as stack:
            stack.enter_context(
                patch("contora_benchmark.runner.process_tree_rss_bytes", return_value=1)
            )
            stack.enter_context(patch("contora_benchmark.runner.swap_used_bytes", return_value=1200))
            stack.enter_context(
                patch("contora_benchmark.runner.memory_free_percent", return_value=50)
            )
            stack.enter_context(patch("contora_benchmark.runner.thermal_snapshot", return_value=[]))
            monitor._sample_once()
        self.assertIn("swap growth exceeded", monitor.abort_reason or "")

    def test_sustained_swap_is_only_computed_for_long_runs(self):
        short = ProcessMonitor(1)
        short.samples = [
            {"timestamp": float(index * 10), "process_tree_rss_bytes": 1, "swap_used_bytes": index, "memory_free_percent": 50, "thermal": []}
            for index in range(10)
        ]
        self.assertIsNone(short.summary()["sustained_swap_growth_bytes"])
        long = ProcessMonitor(1)
        long.samples = [
            {"timestamp": float(index * 70), "process_tree_rss_bytes": 1, "swap_used_bytes": index * 100, "memory_free_percent": 50, "thermal": []}
            for index in range(10)
        ]
        self.assertGreater(long.summary()["sustained_swap_growth_bytes"], 0)

    def test_environment_variables_and_run_placeholders_can_coexist(self):
        previous = os.environ.get("CONTORA_TEST_ROOT")
        os.environ["CONTORA_TEST_ROOT"] = "/tmp/runtime"
        try:
            command = _expand_command(
                ["${CONTORA_TEST_ROOT}/python", "--audio", "{audio}", "--run", "{run_index}"],
                audio=Path("/tmp/audio.wav"),
                output=Path("/tmp/result.json"),
                sample_id="sample",
                run_index=2,
            )
        finally:
            if previous is None:
                os.environ.pop("CONTORA_TEST_ROOT", None)
            else:
                os.environ["CONTORA_TEST_ROOT"] = previous
        self.assertEqual(command, ["/tmp/runtime/python", "--audio", "/tmp/audio.wav", "--run", "2"])

    def test_unresolved_environment_variable_is_rejected(self):
        previous = os.environ.pop("CONTORA_MISSING_ROOT", None)
        try:
            with self.assertRaisesRegex(BenchmarkConfigError, "unresolved environment variable"):
                _expand_command(
                    ["${CONTORA_MISSING_ROOT}/python"],
                    audio=Path("/tmp/audio.wav"),
                    output=Path("/tmp/result.json"),
                    sample_id="sample",
                    run_index=0,
                )
        finally:
            if previous is not None:
                os.environ["CONTORA_MISSING_ROOT"] = previous


if __name__ == "__main__":
    unittest.main()
