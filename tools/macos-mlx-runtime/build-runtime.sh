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
ENABLE_FLUID_ANE="${CONTORA_MLX_INCLUDE_FLUID_ANE:-0}"
FLUID_MODELS_SOURCE="${CONTORA_FLUID_MODELS_ROOT:-}"
FLUID_MODEL_REVISION="1ed7a662fdc7109e36d822db793ee6eebdaf8594"

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

if [[ "$ENABLE_FLUID_ANE" == "1" ]]; then
  if [[ -z "$FLUID_MODELS_SOURCE" ]]; then
    echo "CONTORA_FLUID_MODELS_ROOT is required when CONTORA_MLX_INCLUDE_FLUID_ANE=1" >&2
    exit 1
  fi
  FLUID_MODEL_SOURCE="$FLUID_MODELS_SOURCE/speaker-diarization-coreml"
  FLUID_MARKER="$FLUID_MODEL_SOURCE/.contora-model-revision"
  if [[ ! -f "$FLUID_MARKER" ]] || [[ "$(tr -d '[:space:]' < "$FLUID_MARKER")" != "$FLUID_MODEL_REVISION" ]]; then
    echo "FluidAudio model snapshot is missing or not pinned to $FLUID_MODEL_REVISION" >&2
    exit 1
  fi
  swift build \
    --package-path "$REPO_ROOT/tools/macos-transcription-benchmark/native" \
    -c release \
    --product contora-fluid-diarize \
    -Xswiftc -swift-version -Xswiftc 5
  FLUID_BIN_ROOT="$(swift build --package-path "$REPO_ROOT/tools/macos-transcription-benchmark/native" -c release --show-bin-path)"
  install -m 755 "$FLUID_BIN_ROOT/contora-fluid-diarize" "$RUNTIME_ROOT/bin/contora-fluid-diarize"
  mkdir -p "$RUNTIME_ROOT/models" "$RUNTIME_ROOT/licenses"
  ditto "$FLUID_MODEL_SOURCE" "$RUNTIME_ROOT/models/speaker-diarization-coreml"
  install -m 644 \
    "$REPO_ROOT/tools/macos-transcription-benchmark/native/.build/checkouts/FluidAudio/LICENSE" \
    "$RUNTIME_ROOT/licenses/FluidAudio-Apache-2.0.txt"
  install -m 644 \
    "$REPO_ROOT/tools/macos-mlx-runtime/FluidAudio-model-NOTICE.txt" \
    "$RUNTIME_ROOT/licenses/FluidAudio-model-NOTICE.txt"
fi

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
  "fluidANEIncluded": $([[ "$ENABLE_FLUID_ANE" == "1" ]] && echo true || echo false),
  "fluidAudioVersion": $([[ "$ENABLE_FLUID_ANE" == "1" ]] && echo '"0.9.1"' || echo null),
  "fluidModelRevision": $([[ "$ENABLE_FLUID_ANE" == "1" ]] && echo '"'"$FLUID_MODEL_REVISION"'"' || echo null),
  "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

tar -C "$BUILD_ROOT" -czf "$DIST_ROOT/$ARCHIVE_NAME" mlx-audio
shasum -a 256 "$DIST_ROOT/$ARCHIVE_NAME" > "$DIST_ROOT/$ARCHIVE_NAME.sha256"
echo "$DIST_ROOT/$ARCHIVE_NAME"
