#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${CONTORA_MLX_BUILD_ROOT:-$REPO_ROOT/artifacts/macos-mlx-runtime/build}"
DIST_ROOT="${CONTORA_MLX_DIST_ROOT:-$REPO_ROOT/artifacts/macos-mlx-runtime/dist}"
RUNTIME_ROOT="$BUILD_ROOT/mlx-audio"
SOURCE_VENV="${CONTORA_MLX_SOURCE_VENV:-}"
PYTHON_BIN="${CONTORA_MLX_BUILD_PYTHON:-python3.12}"
ARCHIVE_NAME="${CONTORA_MLX_ARCHIVE_NAME:-ContoraMacMLXRuntime-$(uname -m).tar.gz}"

rm -rf "$BUILD_ROOT" "$DIST_ROOT"
mkdir -p "$RUNTIME_ROOT/venv/lib/python3.12" "$RUNTIME_ROOT/bin" "$DIST_ROOT"

if [[ -z "$SOURCE_VENV" ]]; then
  SOURCE_VENV="$BUILD_ROOT/source-venv"
  "$PYTHON_BIN" -m venv "$SOURCE_VENV"
  "$SOURCE_VENV/bin/python" -m pip install --upgrade pip setuptools wheel
  "$SOURCE_VENV/bin/python" -m pip install "mlx-audio[stt,server]==0.3.1" python-multipart
fi

if [[ ! -d "$SOURCE_VENV/lib/python3.12/site-packages/mlx_audio" ]] || \
   [[ ! -d "$SOURCE_VENV/lib/python3.12/site-packages/mlx" ]]; then
  echo "Source venv does not contain mlx_audio and mlx: $SOURCE_VENV" >&2
  exit 1
fi

ditto \
  "$SOURCE_VENV/lib/python3.12/site-packages" \
  "$RUNTIME_ROOT/venv/lib/python3.12/site-packages"
install -m 755 \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/Resources/contora_mlx_server.py" \
  "$RUNTIME_ROOT/bin/contora_mlx_server.py"

find "$RUNTIME_ROOT" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$RUNTIME_ROOT" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

cat > "$RUNTIME_ROOT/runtime-manifest.json" <<EOF
{
  "schemaVersion": "1.0",
  "runtimeId": "mlx-audio",
  "mlxAudioVersion": "0.3.1",
  "platform": "macos",
  "architecture": "$(uname -m)",
  "pythonVersion": "3.12",
  "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

tar -C "$BUILD_ROOT" -czf "$DIST_ROOT/$ARCHIVE_NAME" mlx-audio
shasum -a 256 "$DIST_ROOT/$ARCHIVE_NAME" > "$DIST_ROOT/$ARCHIVE_NAME.sha256"
echo "$DIST_ROOT/$ARCHIVE_NAME"
