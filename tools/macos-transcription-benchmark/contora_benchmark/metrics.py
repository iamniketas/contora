from __future__ import annotations

import math
import re
import statistics
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Any, Iterable, Sequence

try:
    from rapidfuzz.distance import Levenshtein as _RapidLevenshtein
except ImportError:  # Unit tests and tiny ad-hoc uses retain a dependency-free fallback.
    _RapidLevenshtein = None


TOKEN_RE = re.compile(r"[^\W_]+(?:[-'][^\W_]+)*", re.UNICODE)
PUNCTUATION_RE = re.compile(r"[^\w\s]", re.UNICODE)


def normalize_text(text: str) -> str:
    """Normalize Russian text for WER without erasing letters or digits."""
    value = unicodedata.normalize("NFKC", str(text)).casefold().replace("ё", "е")
    return " ".join(TOKEN_RE.findall(value))


def words(text: str) -> list[str]:
    normalized = normalize_text(text)
    return normalized.split() if normalized else []


@dataclass(frozen=True)
class EditCounts:
    substitutions: int
    deletions: int
    insertions: int
    reference_length: int

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def rate(self) -> float:
        if self.reference_length == 0:
            return 0.0 if self.errors == 0 else 1.0
        return self.errors / self.reference_length


def edit_counts(reference: Sequence[str], hypothesis: Sequence[str]) -> EditCounts:
    """Levenshtein counts with deterministic tie-breaking."""
    if _RapidLevenshtein is not None:
        substitutions = deletions = insertions = 0
        for operation in _RapidLevenshtein.editops(reference, hypothesis):
            if operation.tag == "replace":
                substitutions += 1
            elif operation.tag == "delete":
                deletions += 1
            elif operation.tag == "insert":
                insertions += 1
        return EditCounts(substitutions, deletions, insertions, len(reference))
    if len(reference) * len(hypothesis) > 1_000_000:
        raise RuntimeError(
            "rapidfuzz is required for long-corpus WER/CER scoring; use the benchmark venv"
        )
    previous = [(index, 0, 0, index) for index in range(len(hypothesis) + 1)]
    for ref_index, ref_token in enumerate(reference, start=1):
        current = [(ref_index, 0, ref_index, 0)]
        for hyp_index, hyp_token in enumerate(hypothesis, start=1):
            if ref_token == hyp_token:
                current.append(previous[hyp_index - 1])
                continue
            substitution = previous[hyp_index - 1]
            deletion = previous[hyp_index]
            insertion = current[hyp_index - 1]
            candidates = [
                (substitution[0] + 1, substitution[1] + 1, substitution[2], substitution[3]),
                (deletion[0] + 1, deletion[1], deletion[2] + 1, deletion[3]),
                (insertion[0] + 1, insertion[1], insertion[2], insertion[3] + 1),
            ]
            current.append(min(candidates))
        previous = current
    _, substitutions, deletions, insertions = previous[-1]
    return EditCounts(substitutions, deletions, insertions, len(reference))


def text_error_metrics(reference: str, hypothesis: str) -> dict[str, Any]:
    ref_words = words(reference)
    hyp_words = words(hypothesis)
    word_edits = edit_counts(ref_words, hyp_words)
    ref_chars = list("".join(ref_words))
    hyp_chars = list("".join(hyp_words))
    char_edits = edit_counts(ref_chars, hyp_chars)
    return {
        "wer": word_edits.rate,
        "cer": char_edits.rate,
        "word_errors": word_edits.errors,
        "reference_words": word_edits.reference_length,
        "char_errors": char_edits.errors,
        "reference_chars": char_edits.reference_length,
        "word_edits": {
            "substitutions": word_edits.substitutions,
            "deletions": word_edits.deletions,
            "insertions": word_edits.insertions,
        },
    }


def punctuation_f1(reference: str, hypothesis: str) -> dict[str, float | int]:
    ref = Counter(PUNCTUATION_RE.findall(unicodedata.normalize("NFKC", reference)))
    hyp = Counter(PUNCTUATION_RE.findall(unicodedata.normalize("NFKC", hypothesis)))
    true_positive = sum((ref & hyp).values())
    predicted = sum(hyp.values())
    expected = sum(ref.values())
    precision = true_positive / predicted if predicted else (1.0 if expected == 0 else 0.0)
    recall = true_positive / expected if expected else 1.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {
        "punctuation_precision": precision,
        "punctuation_recall": recall,
        "punctuation_f1": f1,
        "reference_punctuation": expected,
    }


def _turn(turn: dict[str, Any]) -> tuple[float, float, str]:
    start = float(turn["start"])
    end = float(turn["end"])
    speaker = str(turn["speaker"])
    if not math.isfinite(start) or not math.isfinite(end) or end <= start:
        raise ValueError(f"invalid speaker turn: {turn!r}")
    return start, end, speaker


def _overlap(a: tuple[float, float], b: tuple[float, float]) -> float:
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def optimal_speaker_mapping(
    reference_turns: Sequence[dict[str, Any]], hypothesis_turns: Sequence[dict[str, Any]]
) -> dict[str, str]:
    """Find a one-to-one hypothesis-to-reference mapping maximizing overlap."""
    reference = [_turn(item) for item in reference_turns]
    hypothesis = [_turn(item) for item in hypothesis_turns]
    ref_speakers = sorted({speaker for _, _, speaker in reference})
    hyp_speakers = sorted({speaker for _, _, speaker in hypothesis})
    size = max(len(ref_speakers), len(hyp_speakers))
    if size == 0:
        return {}

    weights = [[0.0 for _ in range(size)] for _ in range(size)]
    ref_index = {speaker: index for index, speaker in enumerate(ref_speakers)}
    hyp_index = {speaker: index for index, speaker in enumerate(hyp_speakers)}
    for ref_start, ref_end, ref_speaker in reference:
        for hyp_start, hyp_end, hyp_speaker in hypothesis:
            weights[hyp_index[hyp_speaker]][ref_index[ref_speaker]] += _overlap(
                (ref_start, ref_end), (hyp_start, hyp_end)
            )

    # Hungarian algorithm. Padding with zero-weight dummy speakers handles rectangular matrices.
    max_weight = max(max(row) for row in weights)
    costs = [[max_weight - value for value in row] for row in weights]
    u = [0.0] * (size + 1)
    v = [0.0] * (size + 1)
    p = [0] * (size + 1)
    way = [0] * (size + 1)
    for row in range(1, size + 1):
        p[0] = row
        min_values = [math.inf] * (size + 1)
        used = [False] * (size + 1)
        column = 0
        while True:
            used[column] = True
            active_row = p[column]
            delta = math.inf
            next_column = 0
            for candidate in range(1, size + 1):
                if used[candidate]:
                    continue
                current = costs[active_row - 1][candidate - 1] - u[active_row] - v[candidate]
                if current < min_values[candidate]:
                    min_values[candidate] = current
                    way[candidate] = column
                if min_values[candidate] < delta:
                    delta = min_values[candidate]
                    next_column = candidate
            for candidate in range(size + 1):
                if used[candidate]:
                    u[p[candidate]] += delta
                    v[candidate] -= delta
                else:
                    min_values[candidate] -= delta
            column = next_column
            if p[column] == 0:
                break
        while True:
            next_column = way[column]
            p[column] = p[next_column]
            column = next_column
            if column == 0:
                break

    assignment = {p[column] - 1: column - 1 for column in range(1, size + 1)}
    return {
        hyp_speakers[hyp_row]: ref_speakers[ref_column]
        for hyp_row, ref_column in assignment.items()
        if hyp_row < len(hyp_speakers) and ref_column < len(ref_speakers)
    }


def diarization_metrics(
    reference_turns: Sequence[dict[str, Any]],
    hypothesis_turns: Sequence[dict[str, Any]],
    *,
    collar_seconds: float = 0.0,
    score_overlap: bool = True,
) -> dict[str, Any]:
    reference = [_turn(item) for item in reference_turns]
    hypothesis = [_turn(item) for item in hypothesis_turns]
    mapping = optimal_speaker_mapping(reference_turns, hypothesis_turns)
    ignored = [
        (max(0.0, boundary - collar_seconds), boundary + collar_seconds)
        for start, end, _ in reference
        for boundary in (start, end)
        if collar_seconds > 0
    ]
    boundaries = sorted(
        {value for start, end, _ in reference + hypothesis for value in (start, end)}
        | {value for start, end in ignored for value in (start, end)}
    )
    miss = false_alarm = confusion = denominator = scored = 0.0
    for start, end in zip(boundaries, boundaries[1:]):
        duration = end - start
        if duration <= 0:
            continue
        midpoint = (start + end) / 2
        if any(left <= midpoint <= right for left, right in ignored):
            continue
        ref_active = {speaker for left, right, speaker in reference if left < midpoint < right}
        hyp_active = {
            mapping.get(speaker, f"__unmapped__{speaker}")
            for left, right, speaker in hypothesis
            if left < midpoint < right
        }
        if not score_overlap and len(ref_active) > 1:
            continue
        if not ref_active and not hyp_active:
            continue
        denominator += len(ref_active) * duration
        scored += duration
        miss += max(0, len(ref_active) - len(hyp_active)) * duration
        false_alarm += max(0, len(hyp_active) - len(ref_active)) * duration
        confusion += (min(len(ref_active), len(hyp_active)) - len(ref_active & hyp_active)) * duration
    errors = miss + false_alarm + confusion
    rate = errors / denominator if denominator else (0.0 if errors == 0 else 1.0)
    return {
        "der": rate,
        "miss_seconds": miss,
        "false_alarm_seconds": false_alarm,
        "confusion_seconds": confusion,
        "reference_speaker_seconds": denominator,
        "scored_timeline_seconds": scored,
        "reference_speakers": len({speaker for _, _, speaker in reference}),
        "hypothesis_speakers": len({speaker for _, _, speaker in hypothesis}),
        "speaker_count_error": abs(
            len({speaker for _, _, speaker in reference})
            - len({speaker for _, _, speaker in hypothesis})
        ),
        "speaker_mapping": mapping,
        "collar_seconds": collar_seconds,
        "score_overlap": score_overlap,
    }


def _normalized_word(item: dict[str, Any]) -> str:
    token = words(str(item.get("text", item.get("word", ""))))
    return token[0] if token else ""


def _alignment(reference: Sequence[str], hypothesis: Sequence[str]) -> list[tuple[int | None, int | None]]:
    rows = len(reference) + 1
    columns = len(hypothesis) + 1
    distance = [[0] * columns for _ in range(rows)]
    back: list[list[tuple[int, int] | None]] = [[None] * columns for _ in range(rows)]
    for row in range(1, rows):
        distance[row][0] = row
        back[row][0] = (row - 1, 0)
    for column in range(1, columns):
        distance[0][column] = column
        back[0][column] = (0, column - 1)
    for row in range(1, rows):
        for column in range(1, columns):
            substitution_cost = 0 if reference[row - 1] == hypothesis[column - 1] else 1
            choices = [
                (distance[row - 1][column - 1] + substitution_cost, row - 1, column - 1),
                (distance[row - 1][column] + 1, row - 1, column),
                (distance[row][column - 1] + 1, row, column - 1),
            ]
            best = min(choices)
            distance[row][column] = best[0]
            back[row][column] = (best[1], best[2])
    aligned: list[tuple[int | None, int | None]] = []
    row, column = len(reference), len(hypothesis)
    while row or column:
        previous = back[row][column]
        assert previous is not None
        previous_row, previous_column = previous
        aligned.append(
            (
                row - 1 if previous_row == row - 1 else None,
                column - 1 if previous_column == column - 1 else None,
            )
        )
        row, column = previous
    aligned.reverse()
    return aligned


def word_boundary_metrics(
    reference_words: Sequence[dict[str, Any]], hypothesis_words: Sequence[dict[str, Any]]
) -> dict[str, Any]:
    ref_tokens = [_normalized_word(item) for item in reference_words]
    hyp_tokens = [_normalized_word(item) for item in hypothesis_words]
    errors: list[float] = []
    start_errors: list[float] = []
    end_errors: list[float] = []
    matched = 0
    for ref_index, hyp_index in _alignment(ref_tokens, hyp_tokens):
        if ref_index is None or hyp_index is None or ref_tokens[ref_index] != hyp_tokens[hyp_index]:
            continue
        reference = reference_words[ref_index]
        hypothesis = hypothesis_words[hyp_index]
        start_error = abs(float(reference["start"]) - float(hypothesis["start"]))
        end_error = abs(float(reference["end"]) - float(hypothesis["end"]))
        start_errors.append(start_error)
        end_errors.append(end_error)
        errors.extend((start_error, end_error))
        matched += 1
    ordered = sorted(errors)
    p95_index = max(0, math.ceil(0.95 * len(ordered)) - 1) if ordered else 0
    return {
        "matched_words": matched,
        "reference_words": len(reference_words),
        "match_coverage": matched / len(reference_words) if reference_words else 1.0,
        "mean_absolute_boundary_error_seconds": statistics.fmean(errors) if errors else None,
        "median_absolute_boundary_error_seconds": statistics.median(errors) if errors else None,
        "p95_absolute_boundary_error_seconds": ordered[p95_index] if ordered else None,
        "mean_start_error_seconds": statistics.fmean(start_errors) if start_errors else None,
        "mean_end_error_seconds": statistics.fmean(end_errors) if end_errors else None,
    }


def speaker_attributed_wer(
    reference_words: Sequence[dict[str, Any]],
    hypothesis_words: Sequence[dict[str, Any]],
    speaker_mapping: dict[str, str],
) -> dict[str, Any]:
    ref_by_speaker: dict[str, list[str]] = defaultdict(list)
    hyp_by_speaker: dict[str, list[str]] = defaultdict(list)
    for item in reference_words:
        ref_by_speaker[str(item.get("speaker", "UNKNOWN"))].append(_normalized_word(item))
    for item in hypothesis_words:
        speaker = str(item.get("speaker", "UNKNOWN"))
        hyp_by_speaker[speaker_mapping.get(speaker, f"UNMAPPED:{speaker}")].append(_normalized_word(item))
    substitutions = deletions = insertions = reference_length = 0
    for speaker in sorted(set(ref_by_speaker) | set(hyp_by_speaker)):
        counts = edit_counts(ref_by_speaker[speaker], hyp_by_speaker[speaker])
        substitutions += counts.substitutions
        deletions += counts.deletions
        insertions += counts.insertions
        reference_length += counts.reference_length
    errors = substitutions + deletions + insertions
    return {
        "sa_wer": errors / reference_length if reference_length else (0.0 if errors == 0 else 1.0),
        "speaker_attributed_word_errors": errors,
        "reference_words": reference_length,
        "word_edits": {
            "substitutions": substitutions,
            "deletions": deletions,
            "insertions": insertions,
        },
    }


def tagged_word_recall(
    reference_words: Sequence[dict[str, Any]], hypothesis_words: Sequence[dict[str, Any]]
) -> dict[str, dict[str, float | int]]:
    hypothesis = Counter(_normalized_word(item) for item in hypothesis_words)
    by_tag: dict[str, Counter[str]] = defaultdict(Counter)
    for item in reference_words:
        token = _normalized_word(item)
        tags = list(item.get("tags") or [])
        if any(character.isdigit() for character in token):
            tags.append("number")
        for tag in tags:
            by_tag[str(tag)][token] += 1
    result: dict[str, dict[str, float | int]] = {}
    for tag, expected in sorted(by_tag.items()):
        total = sum(expected.values())
        matched = sum(min(count, hypothesis[token]) for token, count in expected.items())
        result[tag] = {"matched": matched, "reference": total, "recall": matched / total if total else 1.0}
    return result


def score_prediction(
    reference: dict[str, Any],
    prediction: dict[str, Any],
    *,
    collar_seconds: float = 0.0,
    score_overlap: bool = True,
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    reference_text = str(reference.get("text") or "")
    hypothesis_text = str(prediction.get("text") or "")
    if reference_text:
        result["asr"] = {
            **text_error_metrics(reference_text, hypothesis_text),
            **punctuation_f1(reference_text, hypothesis_text),
        }
    reference_turns = list(reference.get("speaker_turns") or [])
    hypothesis_turns = list(prediction.get("speaker_turns") or [])
    mapping: dict[str, str] = {}
    if reference_turns and hypothesis_turns:
        result["diarization"] = diarization_metrics(
            reference_turns,
            hypothesis_turns,
            collar_seconds=collar_seconds,
            score_overlap=score_overlap,
        )
        mapping = result["diarization"]["speaker_mapping"]
    reference_word_items = list(reference.get("words") or [])
    hypothesis_word_items = list(prediction.get("words") or [])
    if reference_word_items and hypothesis_word_items:
        result["word_boundaries"] = word_boundary_metrics(reference_word_items, hypothesis_word_items)
        result["tagged_word_recall"] = tagged_word_recall(reference_word_items, hypothesis_word_items)
        if all("speaker" in item for item in reference_word_items + hypothesis_word_items):
            result["speaker_attributed_asr"] = speaker_attributed_wer(
                reference_word_items, hypothesis_word_items, mapping
            )
    return result


def weighted_rate(items: Iterable[dict[str, Any]], error_key: str, reference_key: str) -> float | None:
    materialized = list(items)
    denominator = sum(float(item.get(reference_key) or 0.0) for item in materialized)
    if denominator <= 0:
        return None
    return sum(float(item.get(error_key) or 0.0) for item in materialized) / denominator
