#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/contora-process-service-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

chmod +x "$SCRIPT_DIR/fake_transcriber.py"

swiftc \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/SharedRuntimePaths.swift" \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/FasterWhisperProcessTranscriptionService.swift" \
  "$SCRIPT_DIR/ProcessServiceSmokeTest.swift" \
  -o "$TEST_ROOT/process-service-smoke-test"

"$TEST_ROOT/process-service-smoke-test" "$SCRIPT_DIR/fake_transcriber.py"
