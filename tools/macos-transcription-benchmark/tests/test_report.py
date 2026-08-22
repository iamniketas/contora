from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from contora_benchmark.report import build_performance_report


class PerformanceReportTests(unittest.TestCase):
    def test_performance_report_never_selects_quality_winner(self):
        record = {
            "state": "completed",
            "sample_id": "sample-2m",
            "cache_state": "cold",
            "elapsed_seconds": 10.0,
            "real_time_factor": 0.1,
            "speed_factor": 10.0,
            "engine": {
                "id": "fast-engine",
                "kind": "asr",
                "version": "1",
                "model": "model",
                "model_revision": "revision",
                "license": "MIT",
            },
            "resources": {
                "peak_process_tree_rss_bytes": 1024,
                "swap_growth_bytes": 0,
                "thermal_warnings": [],
            },
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs = root / "runs.json"
            runs.write_text(
                json.dumps(
                    {
                        "corpus_id": "performance",
                        "corpus_revision": "1",
                        "host": {},
                        "records": [record],
                    }
                ),
                encoding="utf-8",
            )
            report = build_performance_report(
                runs_path=runs,
                output_json=root / "report.json",
                output_markdown=root / "report.md",
            )
            self.assertFalse(report["quality_winner_selected"])
            self.assertIn("No winner selected", (root / "report.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
