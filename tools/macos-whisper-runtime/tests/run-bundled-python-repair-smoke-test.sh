#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ARCHIVE="${CONTORA_WHISPER_RUNTIME_ARCHIVE:-$REPO_ROOT/artifacts/macos-whisper-runtime/dist/ContoraMacWhisperRuntime-$(uname -m).tar.gz}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/contora-python-repair-test.XXXXXX")"
SHARED_ROOT="$TEST_ROOT/runtime"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Whisper runtime archive not found: $ARCHIVE" >&2
  exit 1
fi

mkdir -p "$SHARED_ROOT/faster-whisper-xxl"
tar -xzf "$ARCHIVE" \
  -C "$SHARED_ROOT/faster-whisper-xxl" \
  --strip-components=1 \
  faster-whisper-xxl/python

swiftc -parse-as-library \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/SharedRuntimePaths.swift" \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/FasterWhisperRuntimeInstaller.swift" \
  "$SCRIPT_DIR/BundledPythonRepairSmokeTest.swift" \
  -o "$TEST_ROOT/repair-smoke-test"

"$TEST_ROOT/repair-smoke-test" "$SHARED_ROOT"
