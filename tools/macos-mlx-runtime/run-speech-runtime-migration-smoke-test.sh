#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/contora-speech-runtime-test.XXXXXX")"
trap 'find "$TEST_ROOT" -type f -delete; rmdir "$TEST_ROOT"' EXIT

swiftc \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/SharedRuntimePaths.swift" \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/SharedTranscriptionServerConfig.swift" \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/LegacySpeechRuntimeCleanup.swift" \
  "$SCRIPT_DIR/SpeechRuntimeMigrationSmokeTest.swift" \
  -o "$TEST_ROOT/speech-runtime-migration-test"

"$TEST_ROOT/speech-runtime-migration-test"
