from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .report import build_performance_report, build_report, score_runs
from .runner import run_benchmark
from .schema import BenchmarkConfigError, validate_corpus, validate_engines


def _path(value: str) -> Path:
    return Path(value).expanduser().resolve()


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Contora Apple Silicon transcription benchmark")
    commands = root.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate", help="Validate corpus and engine manifests")
    validate.add_argument("--corpus", required=True, type=_path)
    validate.add_argument("--engines", type=_path)
    validate.add_argument("--verify-audio", action="store_true")

    run = commands.add_parser("run", help="Run selected engines on the corpus")
    run.add_argument("--corpus", required=True, type=_path)
    run.add_argument("--engines", required=True, type=_path)
    run.add_argument("--output", required=True, type=_path)
    run.add_argument("--repetitions", type=int, default=2)
    run.add_argument("--engine", action="append", dest="selected_engines")
    run.add_argument("--sample", action="append", dest="selected_samples")
    run.add_argument("--dry-run", action="store_true")

    score = commands.add_parser("score", help="Score canonical predictions against golden references")
    score.add_argument("--corpus", required=True, type=_path)
    score.add_argument("--runs", required=True, type=_path)
    score.add_argument("--output", required=True, type=_path)

    report = commands.add_parser("report", help="Aggregate scores and apply the quality gate")
    report.add_argument("--corpus", required=True, type=_path)
    report.add_argument("--scores", required=True, type=_path)
    report.add_argument("--output-json", required=True, type=_path)
    report.add_argument("--output-markdown", required=True, type=_path)

    performance_report = commands.add_parser(
        "performance-report", help="Aggregate timings without making quality claims"
    )
    performance_report.add_argument("--corpus", required=True, type=_path)
    performance_report.add_argument("--runs", required=True, type=_path)
    performance_report.add_argument("--output-json", required=True, type=_path)
    performance_report.add_argument("--output-markdown", required=True, type=_path)
    return root


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        corpus = validate_corpus(
            arguments.corpus,
            verify_audio=getattr(arguments, "verify_audio", False) or arguments.command == "run",
        )
        if arguments.command == "validate":
            if arguments.engines:
                validate_engines(arguments.engines)
            print(f"valid corpus: {corpus['corpus']['id']} ({len(corpus['samples'])} samples)")
            return 0
        if arguments.command == "run":
            engines = validate_engines(arguments.engines)
            result = run_benchmark(
                corpus=corpus,
                corpus_path=arguments.corpus,
                engines=engines,
                engines_path=arguments.engines,
                output_root=arguments.output,
                repetitions=arguments.repetitions,
                selected_engines=set(arguments.selected_engines or []),
                selected_samples=set(arguments.selected_samples or []),
                dry_run=arguments.dry_run,
            )
            print(f"wrote {len(result['records'])} runs to {arguments.output}")
            return 0 if all(item["state"] in {"completed", "dry-run"} for item in result["records"]) else 2
        if arguments.command == "score":
            if corpus["corpus"]["reference_policy"] != "manual-golden":
                raise BenchmarkConfigError("performance-only corpora cannot be quality-scored")
            result = score_runs(
                corpus=corpus,
                corpus_path=arguments.corpus,
                runs_path=arguments.runs,
                output_path=arguments.output,
            )
            print(f"scored {len(result['records'])} runs to {arguments.output}")
            return 0
        if arguments.command == "report":
            result = build_report(
                corpus=corpus,
                scores_path=arguments.scores,
                output_json=arguments.output_json,
                output_markdown=arguments.output_markdown,
            )
            print("winners: " + ", ".join(f"{key}={value or 'none'}" for key, value in result["winners"].items()))
            return 0
        if arguments.command == "performance-report":
            if corpus["corpus"]["reference_policy"] != "performance-only":
                raise BenchmarkConfigError(
                    "performance-report requires a performance-only corpus"
                )
            result = build_performance_report(
                runs_path=arguments.runs,
                output_json=arguments.output_json,
                output_markdown=arguments.output_markdown,
            )
            print(f"wrote {len(result['entries'])} performance rows; no quality winner selected")
            return 0
    except (BenchmarkConfigError, OSError, RuntimeError, ValueError) as exc:
        print(f"benchmark error: {exc}", file=sys.stderr)
        return 2
    return 2
