#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/contora-client-crash-safety.XXXXXX")"
trap 'find "$TEST_ROOT" -type f -delete; rmdir "$TEST_ROOT"' EXIT

swiftc \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/TranscriptionCrashSafety.swift" \
  "$SCRIPT_DIR/ClientCrashSafetySmokeTest.swift" \
  -o "$TEST_ROOT/client-crash-safety-test"

"$TEST_ROOT/client-crash-safety-test"
