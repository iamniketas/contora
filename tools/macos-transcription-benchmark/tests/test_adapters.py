from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


ADAPTERS = Path(__file__).resolve().parents[1] / "adapters"
sys.path.insert(0, str(ADAPTERS))

from common import canonical_asr, require_model_revision  # noqa: E402


class AdapterTests(unittest.TestCase):
    def test_canonical_asr_flattens_word_timestamps(self):
        payload = canonical_asr(
            {
                "text": " Привет ",
                "language": "ru",
                "segments": [
                    {
                        "id": 7,
                        "start": 0.0,
                        "end": 1.0,
                        "text": "Привет",
                        "words": [
                            {"word": "Привет", "start": 0.1, "end": 0.8, "probability": 0.9}
                        ],
                    }
                ],
            },
            engine={"id": "test"},
            timing={"total_seconds": 1.0},
        )
        self.assertEqual(payload["text"], "Привет")
        self.assertEqual(payload["words"][0]["text"], "Привет")
        self.assertEqual(payload["words"][0]["confidence"], 0.9)

    def test_model_revision_marker_is_mandatory_and_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "missing pinned model marker"):
                require_model_revision(root, "expected")
            (root / ".contora-model-revision").write_text("wrong\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "model revision mismatch"):
                require_model_revision(root, "expected")
            (root / ".contora-model-revision").write_text("expected\n", encoding="utf-8")
            require_model_revision(root, "expected")


if __name__ == "__main__":
    unittest.main()
