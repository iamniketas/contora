from __future__ import annotations

import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any

from .metrics import score_prediction, weighted_rate
from .schema import atomic_write_json, read_json, resolve_path


def score_runs(
    *, corpus: dict[str, Any], corpus_path: Path, runs_path: Path, output_path: Path
) -> dict[str, Any]:
    runs = read_json(runs_path)
    samples = {str(item["id"]): item for item in corpus["samples"]}
    scoring = dict(corpus.get("scoring") or {})
    collar = float(scoring.get("collar_seconds") or 0.0)
    score_overlap = bool(scoring.get("score_overlap", True))
    scored: list[dict[str, Any]] = []
    for record in runs.get("records", []):
        item = dict(record)
        if item.get("state") != "completed":
            item["score_state"] = "not-scored"
            scored.append(item)
            continue
        sample = samples[str(item["sample_id"])]
        reference_path = resolve_path(corpus_path.parent, str(sample["reference"]["path"]))
        reference = read_json(reference_path)
        run_directory = runs_path.parent / str(item["engine"]["id"]) / str(item["sample_id"])
        run_directory /= f"run-{int(item['run_index']) + 1:02d}"
        prediction_path = run_directory / "prediction.json"
        prediction = read_json(prediction_path)
        item["metrics"] = score_prediction(
            reference,
            prediction,
            collar_seconds=collar,
            score_overlap=score_overlap,
        )
        item["score_state"] = "scored"
        atomic_write_json(run_directory / "score.json", item["metrics"])
        scored.append(item)
    payload = {
        "schema_version": "1.0",
        "corpus_id": corpus["corpus"]["id"],
        "corpus_revision": corpus["corpus"].get("revision"),
        "scoring": {"collar_seconds": collar, "score_overlap": score_overlap},
        "records": scored,
    }
    atomic_write_json(output_path, payload)
    return payload


def _median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def _aggregate_engine(records: list[dict[str, Any]]) -> dict[str, Any]:
    completed = [item for item in records if item.get("state") == "completed"]
    scored = [item for item in completed if item.get("score_state") == "scored"]
    cold = [float(item["elapsed_seconds"]) for item in completed if item.get("cache_state") == "cold"]
    warm = [
        float(item["elapsed_seconds"])
        for item in completed
        if item.get("cache_state") == "warm-os-cache"
    ]
    asr = [item["metrics"]["asr"] for item in scored if "asr" in item.get("metrics", {})]
    diarization = [
        item["metrics"]["diarization"]
        for item in scored
        if "diarization" in item.get("metrics", {})
    ]
    attributed = [
        item["metrics"]["speaker_attributed_asr"]
        for item in scored
        if "speaker_attributed_asr" in item.get("metrics", {})
    ]
    boundaries = [
        item["metrics"]["word_boundaries"]
        for item in scored
        if "word_boundaries" in item.get("metrics", {})
    ]
    tagged = [item["metrics"]["tagged_word_recall"] for item in scored if "tagged_word_recall" in item.get("metrics", {})]
    resource_items = [item.get("resources") or {} for item in completed]
    aggregate: dict[str, Any] = {
        "engine": records[0]["engine"],
        "runs": len(records),
        "completed_runs": len(completed),
        "failed_runs": len(records) - len(completed),
        "cold_median_seconds": _median(cold),
        "warm_median_seconds": _median(warm),
        "median_rtf": _median([float(item["real_time_factor"]) for item in completed]),
        "median_speed_factor": _median([float(item["speed_factor"]) for item in completed]),
        "peak_process_tree_rss_bytes": max(
            (int(item.get("peak_process_tree_rss_bytes") or 0) for item in resource_items),
            default=0,
        ),
        "maximum_swap_growth_bytes": max(
            (int(item.get("swap_growth_bytes") or 0) for item in resource_items), default=0
        ),
        "maximum_sustained_swap_growth_bytes": max(
            (
                int(item["sustained_swap_growth_bytes"])
                for item in resource_items
                if item.get("sustained_swap_growth_bytes") is not None
            ),
            default=0,
        ),
        "thermal_warnings": sorted(
            {warning for item in resource_items for warning in item.get("thermal_warnings", [])}
        ),
        "semantic_result_consistent": all(
            len(sample_records) >= 2
            and all(item.get("prediction_semantic_sha256") for item in sample_records)
            and len({str(item["prediction_semantic_sha256"]) for item in sample_records}) == 1
            for sample_records in (
                [item for item in completed if str(item.get("sample_id")) == sample_id]
                for sample_id in {str(item.get("sample_id")) for item in completed}
            )
        )
        if completed
        else False,
    }
    if asr:
        aggregate["asr"] = {
            "wer": weighted_rate(asr, "word_errors", "reference_words"),
            "cer": weighted_rate(asr, "char_errors", "reference_chars"),
            "punctuation_f1": _median([float(item["punctuation_f1"]) for item in asr]),
        }
    if tagged:
        tags = sorted({tag for item in tagged for tag in item})
        aggregate["tagged_word_recall"] = {}
        for tag in tags:
            reference = sum(int(item.get(tag, {}).get("reference") or 0) for item in tagged)
            matched = sum(int(item.get(tag, {}).get("matched") or 0) for item in tagged)
            aggregate["tagged_word_recall"][tag] = {
                "matched": matched,
                "reference": reference,
                "recall": matched / reference if reference else 1.0,
            }
    if diarization:
        aggregate["diarization"] = {
            "der": weighted_rate(
                (
                    {
                        "error": float(item["miss_seconds"])
                        + float(item["false_alarm_seconds"])
                        + float(item["confusion_seconds"]),
                        "reference": float(item["reference_speaker_seconds"]),
                    }
                    for item in diarization
                ),
                "error",
                "reference",
            ),
            "mean_speaker_count_error": statistics.fmean(
                float(item["speaker_count_error"]) for item in diarization
            ),
        }
    if attributed:
        aggregate["speaker_attributed_asr"] = {
            "sa_wer": weighted_rate(
                attributed, "speaker_attributed_word_errors", "reference_words"
            )
        }
    if boundaries:
        weighted_sum = 0.0
        weight = 0
        for item in boundaries:
            value = item.get("mean_absolute_boundary_error_seconds")
            matched = int(item.get("matched_words") or 0)
            if value is not None and matched:
                weighted_sum += float(value) * matched
                weight += matched
        aggregate["word_boundaries"] = {
            "mean_absolute_boundary_error_seconds": weighted_sum / weight if weight else None,
            "matched_words": weight,
        }
    return aggregate


def build_performance_report(
    *, runs_path: Path, output_json: Path, output_markdown: Path
) -> dict[str, Any]:
    """Create a redacted performance report without making quality claims."""
    runs = read_json(runs_path)
    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for record in runs.get("records", []):
        grouped[(str(record["engine"]["id"]), str(record["sample_id"]))].append(record)
    entries: list[dict[str, Any]] = []
    for (engine_id, sample_id), records in sorted(grouped.items()):
        aggregate = _aggregate_engine(records)
        aggregate.update({"engine_id": engine_id, "sample_id": sample_id})
        entries.append(aggregate)
    report = {
        "schema_version": "1.0",
        "report_kind": "performance-only",
        "corpus_id": runs.get("corpus_id"),
        "corpus_revision": runs.get("corpus_revision"),
        "host": runs.get("host"),
        "entries": entries,
        "quality_winner_selected": False,
        "decision": "performance measurements cannot select a winner without golden references",
    }
    atomic_write_json(output_json, report)
    output_markdown.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# Apple Silicon performance report — {report['corpus_id']}",
        "",
        "Performance-only evidence. No quality winner is selected by this report.",
        "",
        "| Engine | Sample | Kind | Cold | Warm OS cache | Median RTF | Peak RSS | Swap growth | State |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for item in entries:
        cold = item.get("cold_median_seconds")
        warm = item.get("warm_median_seconds")
        rtf = item.get("median_rtf")
        peak = float(item["peak_process_tree_rss_bytes"]) / 1024**3
        swap = float(item["maximum_swap_growth_bytes"]) / 1024**3
        lines.append(
            f"| {item['engine_id']} | {item['sample_id']} | {item['engine']['kind']} | "
            f"{'—' if cold is None else f'{float(cold):.2f}s'} | "
            f"{'—' if warm is None else f'{float(warm):.2f}s'} | "
            f"{'—' if rtf is None else f'{float(rtf):.4f}'} | "
            f"{peak:.2f} GiB | {swap:.2f} GiB | "
            f"{'complete' if item['failed_runs'] == 0 else 'incomplete'} |"
        )
    lines.extend(
        [
            "",
            "## Decision",
            "",
            "No winner selected. Run `score` and `report` against the manual golden corpus first.",
        ]
    )
    output_markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report


def _quality_gate(
    aggregate: dict[str, Any], baselines: dict[str, dict[str, Any]], gates: dict[str, Any]
) -> dict[str, Any]:
    kind = str(aggregate["engine"]["kind"])
    checks: list[dict[str, Any]] = []

    def check(name: str, value: float | None, maximum: float | None) -> None:
        passed = value is not None and maximum is not None and value <= maximum
        checks.append({"name": name, "value": value, "maximum": maximum, "passed": passed})

    max_memory = int(float(gates.get("max_peak_memory_gib", 12.0)) * 1024**3)
    max_any_swap = int(float(gates.get("max_any_swap_growth_gib", 4.0)) * 1024**3)
    max_swap = int(float(gates.get("max_swap_growth_gib", 0.5)) * 1024**3)
    check("peak memory", float(aggregate["peak_process_tree_rss_bytes"]), float(max_memory))
    check(
        "maximum swap growth",
        float(aggregate["maximum_swap_growth_bytes"]),
        float(max_any_swap),
    )
    check(
        "sustained swap growth",
        float(aggregate["maximum_sustained_swap_growth_bytes"]),
        float(max_swap),
    )
    checks.append(
        {
            "name": "thermal warnings",
            "value": len(aggregate["thermal_warnings"]),
            "maximum": 0,
            "passed": not aggregate["thermal_warnings"],
        }
    )
    checks.append(
        {
            "name": "cold/warm semantic consistency",
            "value": aggregate["semantic_result_consistent"],
            "expected": True,
            "passed": aggregate["semantic_result_consistent"] is True,
        }
    )
    checks.append(
        {
            "name": "all runs completed",
            "value": aggregate["failed_runs"],
            "maximum": 0,
            "passed": aggregate["failed_runs"] == 0,
        }
    )
    asr_baseline = baselines.get("asr")
    if kind in {"asr", "pipeline"}:
        delta = float(gates.get("max_asr_delta_absolute_pp", 0.5)) / 100.0
        if asr_baseline and aggregate.get("asr") and asr_baseline.get("asr"):
            check("WER vs baseline", aggregate["asr"]["wer"], asr_baseline["asr"]["wer"] + delta)
            check("CER vs baseline", aggregate["asr"]["cer"], asr_baseline["asr"]["cer"] + delta)
            minimum_punctuation = float(asr_baseline["asr"]["punctuation_f1"]) - float(
                gates.get("max_punctuation_f1_drop", 0.0)
            )
            punctuation = float(aggregate["asr"]["punctuation_f1"])
            checks.append(
                {
                    "name": "punctuation F1 vs baseline",
                    "value": punctuation,
                    "minimum": minimum_punctuation,
                    "passed": punctuation >= minimum_punctuation,
                }
            )
            for tag in ("name", "number"):
                baseline_tag = (asr_baseline.get("tagged_word_recall") or {}).get(tag)
                candidate_tag = (aggregate.get("tagged_word_recall") or {}).get(tag)
                if baseline_tag and candidate_tag:
                    minimum = float(baseline_tag["recall"]) - float(
                        gates.get("max_tagged_word_recall_drop", 0.0)
                    )
                    value = float(candidate_tag["recall"])
                    checks.append(
                        {
                            "name": f"{tag} recall vs baseline",
                            "value": value,
                            "minimum": minimum,
                            "passed": value >= minimum,
                        }
                    )
                else:
                    checks.append({"name": f"{tag} annotations available", "passed": False})
        else:
            checks.append({"name": "ASR baseline available", "passed": False})
    diar_baseline = baselines.get("diarization")
    if kind in {"diarization", "pipeline"}:
        delta = float(gates.get("max_diarization_delta_absolute_pp", 0.0)) / 100.0
        if diar_baseline and aggregate.get("diarization") and diar_baseline.get("diarization"):
            check(
                "DER vs baseline",
                aggregate["diarization"]["der"],
                diar_baseline["diarization"]["der"] + delta,
            )
        else:
            checks.append({"name": "diarization baseline available", "passed": False})
    if kind == "pipeline":
        if (
            diar_baseline
            and aggregate.get("speaker_attributed_asr")
            and diar_baseline.get("speaker_attributed_asr")
        ):
            check(
                "SA-WER vs baseline",
                aggregate["speaker_attributed_asr"]["sa_wer"],
                diar_baseline["speaker_attributed_asr"]["sa_wer"],
            )
        else:
            checks.append({"name": "SA-WER baseline available", "passed": False})
    return {"passed": all(item.get("passed") is True for item in checks), "checks": checks}


def build_report(
    *, corpus: dict[str, Any], scores_path: Path, output_json: Path, output_markdown: Path
) -> dict[str, Any]:
    scores = read_json(scores_path)
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for record in scores.get("records", []):
        grouped[str(record["engine"]["id"])].append(record)
    aggregates = {engine_id: _aggregate_engine(records) for engine_id, records in grouped.items()}
    baseline_ids = dict((corpus.get("quality_gate") or {}).get("baselines") or {})
    baselines = {
        role: aggregates[engine_id]
        for role, engine_id in baseline_ids.items()
        if engine_id in aggregates
    }
    gates = dict(corpus.get("quality_gate") or {})
    for aggregate in aggregates.values():
        aggregate["quality_gate"] = _quality_gate(aggregate, baselines, gates)
    winners: dict[str, str | None] = {}
    for kind in ("asr", "diarization", "pipeline"):
        candidates = [
            item
            for item in aggregates.values()
            if item["engine"]["kind"] == kind and item["quality_gate"]["passed"]
        ]
        candidates = [item for item in candidates if item.get("warm_median_seconds") is not None]
        winners[kind] = (
            min(candidates, key=lambda item: float(item["warm_median_seconds"]))["engine"]["id"]
            if candidates
            else None
        )
    report = {
        "schema_version": "1.0",
        "corpus_id": scores.get("corpus_id"),
        "corpus_revision": scores.get("corpus_revision"),
        "quality_gate": gates,
        "engines": aggregates,
        "winners": winners,
        "decision": (
            "winner selected only among candidates passing every predeclared quality/resource gate"
        ),
    }
    atomic_write_json(output_json, report)
    output_markdown.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# Apple Silicon transcription bake-off — {report['corpus_id']}",
        "",
        "Only candidates passing every predeclared quality and resource gate are eligible.",
        "",
        "| Engine | Kind | Warm median | RTF | WER | CER | DER | SA-WER | Peak RSS | Gate |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for engine_id, item in sorted(aggregates.items()):
        asr = item.get("asr") or {}
        diar = item.get("diarization") or {}
        sa = item.get("speaker_attributed_asr") or {}
        gib = float(item["peak_process_tree_rss_bytes"]) / 1024**3
        format_rate = lambda value: "—" if value is None else f"{float(value) * 100:.2f}%"
        warm = item.get("warm_median_seconds")
        rtf = item.get("median_rtf")
        warm_text = "—" if warm is None else f"{float(warm):.2f}s"
        rtf_text = "—" if rtf is None else f"{float(rtf):.4f}"
        lines.append(
            f"| {engine_id} | {item['engine']['kind']} | "
            f"{warm_text} | {rtf_text} | "
            f"{format_rate(asr.get('wer'))} | {format_rate(asr.get('cer'))} | "
            f"{format_rate(diar.get('der'))} | {format_rate(sa.get('sa_wer'))} | "
            f"{gib:.2f} GiB | {'PASS' if item['quality_gate']['passed'] else 'FAIL'} |"
        )
    lines.extend(["", "## Winners", ""])
    for kind, winner in winners.items():
        lines.append(f"- {kind}: {winner or 'not selected'}")
    output_markdown.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report
