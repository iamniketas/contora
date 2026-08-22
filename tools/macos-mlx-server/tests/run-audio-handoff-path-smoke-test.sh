#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/contora-audio-handoff-path.XXXXXX")"
trap 'find "$TEST_ROOT" -type f -delete; rmdir "$TEST_ROOT"' EXIT

swiftc \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/MLXAudioHandoffPaths.swift" \
  "$SCRIPT_DIR/AudioHandoffPathSmokeTest.swift" \
  -o "$TEST_ROOT/audio-handoff-path-test"

"$TEST_ROOT/audio-handoff-path-test"
