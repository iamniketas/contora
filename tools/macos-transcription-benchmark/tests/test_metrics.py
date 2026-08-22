from __future__ import annotations

import unittest

from contora_benchmark.metrics import (
    diarization_metrics,
    normalize_text,
    optimal_speaker_mapping,
    speaker_attributed_wer,
    text_error_metrics,
    word_boundary_metrics,
)


class TextMetricsTests(unittest.TestCase):
    def test_russian_normalization_and_edit_counts(self):
        self.assertEqual(normalize_text("Ёлка, 42!"), "елка 42")
        metrics = text_error_metrics("Привет, мир", "Привет миры")
        self.assertEqual(metrics["reference_words"], 2)
        self.assertEqual(metrics["word_errors"], 1)
        self.assertEqual(metrics["wer"], 0.5)


class DiarizationMetricsTests(unittest.TestCase):
    def test_speaker_labels_are_permutation_invariant(self):
        reference = [
            {"start": 0.0, "end": 2.0, "speaker": "Alice"},
            {"start": 2.0, "end": 4.0, "speaker": "Bob"},
        ]
        hypothesis = [
            {"start": 0.0, "end": 2.0, "speaker": "S1"},
            {"start": 2.0, "end": 4.0, "speaker": "S0"},
        ]
        self.assertEqual(optimal_speaker_mapping(reference, hypothesis), {"S0": "Bob", "S1": "Alice"})
        self.assertEqual(diarization_metrics(reference, hypothesis)["der"], 0.0)

    def test_overlap_is_scored(self):
        reference = [
            {"start": 0.0, "end": 2.0, "speaker": "A"},
            {"start": 1.0, "end": 2.0, "speaker": "B"},
        ]
        hypothesis = [{"start": 0.0, "end": 2.0, "speaker": "X"}]
        metrics = diarization_metrics(reference, hypothesis, score_overlap=True)
        self.assertAlmostEqual(metrics["miss_seconds"], 1.0)
        self.assertAlmostEqual(metrics["reference_speaker_seconds"], 3.0)
        self.assertAlmostEqual(metrics["der"], 1.0 / 3.0)

    def test_collar_excludes_only_boundary_region(self):
        reference = [{"start": 1.0, "end": 3.0, "speaker": "A"}]
        hypothesis = [{"start": 1.1, "end": 3.0, "speaker": "X"}]
        self.assertEqual(diarization_metrics(reference, hypothesis, collar_seconds=0.2)["der"], 0.0)


class WordMetricsTests(unittest.TestCase):
    def test_boundaries_only_compare_exactly_aligned_words(self):
        reference = [
            {"text": "Привет", "start": 0.0, "end": 0.5},
            {"text": "мир", "start": 0.6, "end": 1.0},
        ]
        hypothesis = [
            {"text": "Привет", "start": 0.1, "end": 0.6},
            {"text": "дом", "start": 0.7, "end": 1.1},
        ]
        metrics = word_boundary_metrics(reference, hypothesis)
        self.assertEqual(metrics["matched_words"], 1)
        self.assertAlmostEqual(metrics["mean_absolute_boundary_error_seconds"], 0.1)

    def test_speaker_attributed_wer_penalizes_wrong_speaker(self):
        reference = [
            {"text": "да", "speaker": "A"},
            {"text": "нет", "speaker": "B"},
        ]
        hypothesis = [
            {"text": "да", "speaker": "X"},
            {"text": "нет", "speaker": "X"},
        ]
        metrics = speaker_attributed_wer(reference, hypothesis, {"X": "A"})
        self.assertGreater(metrics["sa_wer"], 0.0)


if __name__ == "__main__":
    unittest.main()
