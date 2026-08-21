#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOURCE_ROOT="$REPO_ROOT/apps/macos/Sources/ContoraMac/Resources"

install -m 755 "$SCRIPT_DIR/contora_mlx_server.py" "$RESOURCE_ROOT/contora_mlx_server.py"
install -m 644 "$SCRIPT_DIR/result_safety.py" "$RESOURCE_ROOT/result_safety.py"
