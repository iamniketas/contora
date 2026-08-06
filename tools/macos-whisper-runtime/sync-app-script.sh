#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

install -m 755 \
  "$SCRIPT_DIR/contora_fw_transcribe.py" \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/Resources/contora_fw_transcribe.py"
