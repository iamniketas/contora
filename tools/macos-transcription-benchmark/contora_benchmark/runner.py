from __future__ import annotations

import json
import os
import platform
import re
import signal
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from .schema import (
    BenchmarkConfigError,
    atomic_write_json,
    read_json,
    prediction_semantic_sha256,
    resolve_path,
    sha256_file,
    validate_prediction,
)


SWAP_RE = re.compile(r"used = ([0-9.]+)([MG])")
MEMORY_RE = re.compile(r"System-wide memory free percentage:\s*([0-9]+)%")
POWER_SOURCE_RE = re.compile(r"Now drawing from '([^']+)'")
BATTERY_PERCENT_RE = re.compile(r"\b([0-9]{1,3})%;")
UNRESOLVED_ENV_RE = re.compile(r"\$\{[^}]+\}")


def _command_output(arguments: list[str]) -> str:
    try:
        return subprocess.run(arguments, check=False, capture_output=True, text=True, timeout=15).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def swap_used_bytes() -> int | None:
    output = _command_output(["sysctl", "vm.swapusage"])
    match = SWAP_RE.search(output)
    if not match:
        return None
    multiplier = 1024**2 if match.group(2) == "M" else 1024**3
    return int(float(match.group(1)) * multiplier)


def memory_free_percent() -> int | None:
    output = _command_output(["memory_pressure", "-Q"])
    match = MEMORY_RE.search(output)
    return int(match.group(1)) if match else None


def thermal_snapshot() -> list[str]:
    output = _command_output(["pmset", "-g", "therm"])
    return [line.strip() for line in output.splitlines() if line.strip()]


def power_snapshot() -> dict[str, Any]:
    output = _command_output(["pmset", "-g", "batt"])
    source_match = POWER_SOURCE_RE.search(output)
    battery_match = BATTERY_PERCENT_RE.search(output)
    return {
        "source": source_match.group(1) if source_match else None,
        "battery_percent": int(battery_match.group(1)) if battery_match else None,
        "charging": bool(re.search(r"\b(charging|charged)\b", output.casefold())),
    }


def validate_power_for_benchmark(*, minimum_battery_percent: int = 20) -> dict[str, Any]:
    power = power_snapshot()
    if power["source"] != "AC Power":
        raise BenchmarkConfigError("benchmark requires AC power")
    battery = power["battery_percent"]
    if battery is not None and int(battery) < minimum_battery_percent:
        raise BenchmarkConfigError(
            f"benchmark requires at least {minimum_battery_percent}% battery while charging"
        )
    return power


def hardware_profile() -> dict[str, Any]:
    return {
        "captured_at": time.time(),
        "os": _command_output(["sw_vers", "-productVersion"]),
        "os_build": _command_output(["sw_vers", "-buildVersion"]),
        "architecture": platform.machine(),
        "chip": _command_output(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "memory_bytes": int(_command_output(["sysctl", "-n", "hw.memsize"]) or 0),
        "python": platform.python_version(),
        "swap_used_bytes": swap_used_bytes(),
        "memory_free_percent": memory_free_percent(),
        "thermal": thermal_snapshot(),
        "power": power_snapshot(),
    }


def _process_table() -> dict[int, tuple[int, int]]:
    output = _command_output(["ps", "-axo", "pid=,ppid=,rss="])
    result: dict[int, tuple[int, int]] = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) == 3:
            try:
                result[int(parts[0])] = (int(parts[1]), int(parts[2]))
            except ValueError:
                continue
    return result


def process_tree_rss_bytes(root_pid: int) -> int:
    table = _process_table()
    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (parent, _) in table.items():
            if parent in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    return sum(table.get(pid, (0, 0))[1] for pid in descendants) * 1024


class ProcessMonitor:
    def __init__(
        self,
        pid: int,
        interval_seconds: float = 1.0,
        *,
        maximum_swap_growth_bytes: int = 4 * 1024**3,
        minimum_memory_free_percent: int = 10,
        initial_swap_bytes: int | None = None,
    ):
        self.pid = pid
        self.interval_seconds = interval_seconds
        self.maximum_swap_growth_bytes = maximum_swap_growth_bytes
        self.minimum_memory_free_percent = minimum_memory_free_percent
        self.initial_swap_bytes = initial_swap_bytes
        self.samples: list[dict[str, Any]] = []
        self.abort_reason: str | None = None
        self._low_memory_samples = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._sample_loop, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=max(2.0, self.interval_seconds * 2))

    def _sample_loop(self) -> None:
        while not self._stop.is_set():
            self._sample_once()
            self._stop.wait(self.interval_seconds)

    def _sample_once(self) -> None:
        sample: dict[str, Any] = {
            "timestamp": time.time(),
            "process_tree_rss_bytes": process_tree_rss_bytes(self.pid),
            "swap_used_bytes": swap_used_bytes(),
            "memory_free_percent": memory_free_percent(),
            "thermal": thermal_snapshot(),
        }
        if not self.samples or len(self.samples) % 10 == 0:
            sample["power"] = power_snapshot()
        self.samples.append(sample)
        swap = [item["swap_used_bytes"] for item in self.samples if item["swap_used_bytes"] is not None]
        swap_baseline = self.initial_swap_bytes if self.initial_swap_bytes is not None else (swap[0] if swap else None)
        if swap and swap_baseline is not None and swap[-1] - swap_baseline > self.maximum_swap_growth_bytes:
            self.abort_reason = (
                f"swap growth exceeded {self.maximum_swap_growth_bytes / 1024**3:.1f} GiB"
            )
        free = sample["memory_free_percent"]
        self._low_memory_samples = (
            self._low_memory_samples + 1
            if free is not None and int(free) < self.minimum_memory_free_percent
            else 0
        )
        if self._low_memory_samples >= 3:
            self.abort_reason = (
                f"memory free remained below {self.minimum_memory_free_percent}%"
            )
        power = sample.get("power")
        if power and power.get("source") is not None and power.get("source") != "AC Power":
            self.abort_reason = "AC power disconnected during benchmark"

    def summary(self) -> dict[str, Any]:
        rss = [int(item["process_tree_rss_bytes"]) for item in self.samples]
        swap = [int(item["swap_used_bytes"]) for item in self.samples if item["swap_used_bytes"] is not None]
        free = [int(item["memory_free_percent"]) for item in self.samples if item["memory_free_percent"] is not None]
        warnings = sorted(
            {
                line
                for item in self.samples
                for line in item["thermal"]
                if "No " not in line and "warning" in line.casefold()
            }
        )
        sustained_swap_growth: int | None = None
        if len(swap) >= 3 and self.samples[-1]["timestamp"] - self.samples[0]["timestamp"] >= 600:
            edge_count = max(3, len(swap) // 10)
            start_level = sorted(swap[:edge_count])[edge_count // 2]
            end_level = sorted(swap[-edge_count:])[edge_count // 2]
            sustained_swap_growth = max(0, end_level - start_level)
        return {
            "sample_count": len(self.samples),
            "peak_process_tree_rss_bytes": max(rss, default=0),
            "swap_start_bytes": swap[0] if swap else None,
            "swap_end_bytes": swap[-1] if swap else None,
            "swap_growth_bytes": max(0, swap[-1] - swap[0]) if swap else None,
            "sustained_swap_growth_bytes": sustained_swap_growth,
            "minimum_memory_free_percent": min(free) if free else None,
            "thermal_warnings": warnings,
            "samples": self.samples,
        }


def _expand_command(
    command: list[str], *, audio: Path, output: Path, sample_id: str, run_index: int
) -> list[str]:
    replacements = {
        "audio": str(audio),
        "output": str(output),
        "sample_id": sample_id,
        "run_index": str(run_index),
    }
    expanded: list[str] = []
    for argument in command:
        environment_expanded = os.path.expandvars(os.path.expanduser(argument))
        if UNRESOLVED_ENV_RE.search(environment_expanded):
            raise BenchmarkConfigError(
                f"unresolved environment variable in command argument: {argument}"
            )
        try:
            rendered = environment_expanded.format(**replacements)
        except KeyError as exc:
            raise BenchmarkConfigError(f"unsupported command placeholder: {exc}") from exc
        expanded.append(rendered)
    return expanded


def _terminate_process_group(process: subprocess.Popen[bytes], grace_seconds: float = 10.0) -> int:
    if process.poll() is not None:
        return int(process.returncode or 0)
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        return process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return process.wait(timeout=grace_seconds)


def _run_one(
    *,
    engine: dict[str, Any],
    sample: dict[str, Any],
    corpus_base: Path,
    engine_base: Path,
    run_root: Path,
    run_index: int,
    dry_run: bool,
) -> dict[str, Any]:
    power_before = (
        power_snapshot()
        if dry_run
        else validate_power_for_benchmark(
            minimum_battery_percent=int(engine.get("minimum_battery_percent") or 20)
        )
    )
    engine_id = str(engine["id"])
    sample_id = str(sample["id"])
    audio_path = resolve_path(corpus_base, str(sample["audio"]["path"]))
    prediction_path = run_root / "prediction.json"
    command = _expand_command(
        list(engine["command"]),
        audio=audio_path,
        output=prediction_path,
        sample_id=sample_id,
        run_index=run_index,
    )
    cwd = resolve_path(engine_base, str(engine.get("cwd") or "."))
    timeout_seconds = float(engine.get("timeout_seconds") or 7200.0)
    env = os.environ.copy()
    configured_environment: dict[str, str] = {}
    for key, value in dict(engine.get("env") or {}).items():
        expanded = os.path.expandvars(os.path.expanduser(str(value)))
        # Optional overrides are omitted when not configured, allowing a
        # normal venv to resolve its own standard library and site-packages.
        if UNRESOLVED_ENV_RE.search(expanded):
            continue
        configured_environment[str(key)] = expanded
    env.update(configured_environment)
    metadata: dict[str, Any] = {
        "schema_version": "1.0",
        "engine": {key: engine[key] for key in ("id", "kind", "version", "model", "model_revision", "license")},
        "sample_id": sample_id,
        "audio_sha256": str(sample["audio"].get("sha256") or sha256_file(audio_path)),
        "audio_duration_seconds": float(sample["audio"]["duration_seconds"]),
        "run_index": run_index,
        "cache_state": "cold" if run_index == 0 else "warm-os-cache",
        "cache_semantics": "fresh process each run; warm means immediately repeated with filesystem/model caches warm",
        "command": command,
        "cwd": str(cwd),
        "environment_keys": sorted(configured_environment),
        "started_at": time.time(),
        "power_before": power_before,
        "safety_limits": {
            "maximum_swap_growth_gib": float(engine.get("maximum_swap_growth_gib") or 4.0),
            "minimum_memory_free_percent": int(engine.get("minimum_memory_free_percent") or 10),
        },
        "host_before": hardware_profile(),
    }
    run_root.mkdir(parents=True, exist_ok=True)
    if dry_run:
        metadata.update({"state": "dry-run", "elapsed_seconds": 0.0})
        atomic_write_json(run_root / "run.json", metadata)
        return metadata

    stdout_path = run_root / "stdout.log"
    stderr_path = run_root / "stderr.log"
    started = time.monotonic()
    monitor: ProcessMonitor | None = None
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
        monitor = ProcessMonitor(
            process.pid,
            float(engine.get("sample_interval_seconds") or 1.0),
            maximum_swap_growth_bytes=int(
                float(engine.get("maximum_swap_growth_gib") or 4.0) * 1024**3
            ),
            minimum_memory_free_percent=int(engine.get("minimum_memory_free_percent") or 10),
            initial_swap_bytes=metadata["host_before"].get("swap_used_bytes"),
        )
        monitor.start()
        timed_out = False
        resource_aborted = False
        abort_reason: str | None = None
        try:
            deadline = time.monotonic() + timeout_seconds
            while True:
                if monitor.abort_reason:
                    resource_aborted = True
                    abort_reason = monitor.abort_reason
                    return_code = _terminate_process_group(process)
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout_seconds)
                try:
                    return_code = process.wait(timeout=min(1.0, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
        except KeyboardInterrupt:
            _terminate_process_group(process)
            raise
        except subprocess.TimeoutExpired:
            timed_out = True
            return_code = _terminate_process_group(process)
        finally:
            monitor.stop()
    elapsed = time.monotonic() - started
    metadata.update(
        {
            "finished_at": time.time(),
            "elapsed_seconds": elapsed,
            "real_time_factor": elapsed / float(sample["audio"]["duration_seconds"]),
            "speed_factor": float(sample["audio"]["duration_seconds"]) / elapsed if elapsed else None,
            "return_code": return_code,
            "timed_out": timed_out,
            "resource_aborted": resource_aborted,
            "abort_reason": abort_reason,
            "resources": monitor.summary(),
            "host_after": hardware_profile(),
        }
    )
    if resource_aborted:
        metadata["state"] = "failed"
        metadata["error"] = f"resource safety guard stopped engine: {abort_reason}"
    elif return_code != 0:
        metadata["state"] = "failed"
        metadata["error"] = f"engine exited with code {return_code}"
    elif not prediction_path.is_file():
        metadata["state"] = "failed"
        metadata["error"] = "engine did not create prediction.json"
    else:
        try:
            prediction = read_json(prediction_path)
            validate_prediction(prediction, kind=str(engine["kind"]))
            metadata["state"] = "completed"
            metadata["prediction_sha256"] = sha256_file(prediction_path)
            metadata["prediction_semantic_sha256"] = prediction_semantic_sha256(prediction)
        except BenchmarkConfigError as exc:
            metadata["state"] = "failed"
            metadata["error"] = str(exc)
    atomic_write_json(run_root / "run.json", metadata)
    return metadata


def run_benchmark(
    *,
    corpus: dict[str, Any],
    corpus_path: Path,
    engines: dict[str, Any],
    engines_path: Path,
    output_root: Path,
    repetitions: int,
    selected_engines: set[str] | None = None,
    selected_samples: set[str] | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    if repetitions < 1:
        raise BenchmarkConfigError("repetitions must be at least 1")
    output_root.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, Any]] = []
    safety_aborted = False
    for engine in engines["engines"]:
        engine_id = str(engine["id"])
        if selected_engines and engine_id not in selected_engines:
            continue
        for sample in corpus["samples"]:
            sample_id = str(sample["id"])
            if selected_samples and sample_id not in selected_samples:
                continue
            for run_index in range(repetitions):
                run_root = output_root / engine_id / sample_id / f"run-{run_index + 1:02d}"
                record = _run_one(
                    engine=engine,
                    sample=sample,
                    corpus_base=corpus_path.parent,
                    engine_base=engines_path.parent,
                    run_root=run_root,
                    run_index=run_index,
                    dry_run=dry_run,
                )
                records.append(record)
                if record.get("resource_aborted"):
                    safety_aborted = True
                    break
            if safety_aborted:
                break
        if safety_aborted:
            break
    index = {
        "schema_version": "1.0",
        "created_at": time.time(),
        "corpus_id": corpus["corpus"]["id"],
        "corpus_revision": corpus["corpus"].get("revision"),
        "repetitions": repetitions,
        "safety_aborted": safety_aborted,
        "host": hardware_profile(),
        "records": records,
    }
    atomic_write_json(output_root / "runs.json", index)
    return index
