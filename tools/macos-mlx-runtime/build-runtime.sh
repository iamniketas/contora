#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${CONTORA_SPEECH_BUILD_ROOT:-$REPO_ROOT/artifacts/macos-speech-runtime/build}"
DIST_ROOT="${CONTORA_SPEECH_DIST_ROOT:-$REPO_ROOT/artifacts/macos-speech-runtime/dist}"
RUNTIME_NAME="speech-runtime"
RUNTIME_ROOT="$BUILD_ROOT/$RUNTIME_NAME"
SOURCE_VENV="${CONTORA_SPEECH_SOURCE_VENV:-${CONTORA_MLX_SOURCE_VENV:-}}"
PYTHON_BIN="${CONTORA_SPEECH_BUILD_PYTHON:-${CONTORA_MLX_BUILD_PYTHON:-python3.12}}"
PYTHON_PREFIX="${CONTORA_SPEECH_PYTHON_PREFIX:-}"
PYANNOTE_ASSETS_SOURCE="${CONTORA_PYANNOTE_ASSETS_ROOT:-}"
ARCHIVE_NAME="${CONTORA_SPEECH_ARCHIVE_NAME:-ContoraMacSpeechRuntime-$(uname -m).tar.gz}"
ENABLE_FLUID_ANE="${CONTORA_SPEECH_INCLUDE_FLUID_ANE:-${CONTORA_MLX_INCLUDE_FLUID_ANE:-0}}"
FLUID_MODELS_SOURCE="${CONTORA_FLUID_MODELS_ROOT:-}"
FLUID_MODEL_REVISION="1ed7a662fdc7109e36d822db793ee6eebdaf8594"
PYTHON_VERSION="3.12"

rm -rf "$BUILD_ROOT" "$DIST_ROOT"
mkdir -p "$RUNTIME_ROOT/venv/lib/python$PYTHON_VERSION" "$RUNTIME_ROOT/bin" "$DIST_ROOT"

if [[ -z "$SOURCE_VENV" ]]; then
  SOURCE_VENV="$BUILD_ROOT/source-venv"
  "$PYTHON_BIN" -m venv "$SOURCE_VENV"
  "$SOURCE_VENV/bin/python" -m pip install --upgrade pip setuptools wheel
  "$SOURCE_VENV/bin/python" -m pip install \
    "mlx-audio[stt,server]==0.3.1" \
    "pyannote.audio==3.4.0" \
    "fastapi==0.133.0" \
    "uvicorn==0.41.0" \
    "python-multipart==0.0.22"
fi

SOURCE_SITE_PACKAGES="$SOURCE_VENV/lib/python$PYTHON_VERSION/site-packages"
for package in mlx_audio mlx torch pyannote; do
  if [[ ! -e "$SOURCE_SITE_PACKAGES/$package" ]]; then
    echo "Source venv does not contain required package '$package': $SOURCE_VENV" >&2
    exit 1
  fi
done

if [[ -z "$PYTHON_PREFIX" ]]; then
  PYTHON_PREFIX="$("$SOURCE_VENV/bin/python" -c 'import sys; print(sys.base_prefix)')"
fi
if [[ "$("$SOURCE_VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" != "$PYTHON_VERSION" ]]; then
  echo "The speech runtime requires a Python $PYTHON_VERSION source venv" >&2
  exit 1
fi
if [[ ! -d "$PYTHON_PREFIX" ]]; then
  echo "Relocatable Python source prefix not found: $PYTHON_PREFIX" >&2
  exit 1
fi

mkdir -p "$RUNTIME_ROOT/python/Python.framework/Versions"
ditto "$PYTHON_PREFIX" "$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION"
ditto "$SOURCE_SITE_PACKAGES" "$RUNTIME_ROOT/venv/lib/python$PYTHON_VERSION/site-packages"
if [[ ! -d "$RUNTIME_ROOT/venv/lib/python$PYTHON_VERSION/site-packages/fastapi" ]] || \
   [[ ! -d "$RUNTIME_ROOT/venv/lib/python$PYTHON_VERSION/site-packages/uvicorn" ]] || \
   [[ ! -d "$RUNTIME_ROOT/venv/lib/python$PYTHON_VERSION/site-packages/python_multipart" ]]; then
  "$SOURCE_VENV/bin/python" -m pip install --upgrade \
    --target "$RUNTIME_ROOT/venv/lib/python$PYTHON_VERSION/site-packages" \
    "fastapi==0.133.0" \
    "uvicorn==0.41.0" \
    "python-multipart==0.0.22"
fi

repair_bundled_python_install_names() {
  local framework_root="$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION"
  local framework_lib="$framework_root/Python"
  local framework_lib_dir="$framework_root/lib"
  local dynload_dir="$framework_lib_dir/python$PYTHON_VERSION/lib-dynload"
  local python_bin="$framework_root/bin/python$PYTHON_VERSION"
  local python_app_bin="$framework_root/Resources/Python.app/Contents/MacOS/Python"
  local absolute_ref="/Library/Frameworks/Python.framework/Versions/$PYTHON_VERSION/Python"
  local absolute_ssl="/Library/Frameworks/Python.framework/Versions/$PYTHON_VERSION/lib/libssl.3.dylib"
  local absolute_crypto="/Library/Frameworks/Python.framework/Versions/$PYTHON_VERSION/lib/libcrypto.3.dylib"

  [[ -x "$python_bin" ]] || { echo "Bundled Python executable is missing: $python_bin" >&2; exit 1; }
  command -v install_name_tool >/dev/null 2>&1 || return

  install_name_tool -change "$absolute_ref" "@executable_path/../Python" "$python_bin" || true
  codesign --force --sign - "$python_bin" >/dev/null 2>&1 || true
  if [[ -x "$python_app_bin" ]]; then
    install_name_tool -change "$absolute_ref" "@executable_path/../../../../Python" "$python_app_bin" || true
    codesign --force --sign - "$python_app_bin" >/dev/null 2>&1 || true
  fi
  [[ ! -f "$framework_lib" ]] || codesign --force --sign - "$framework_lib" >/dev/null 2>&1 || true

  repair_dependency() {
    local binary="$1"
    local old_ref="$2"
    local new_ref="$3"
    if [[ -f "$binary" ]] && otool -L "$binary" | grep -Fq "$old_ref"; then
      install_name_tool -change "$old_ref" "$new_ref" "$binary"
      codesign --force --sign - "$binary" >/dev/null 2>&1 || true
    fi
  }

  repair_dependency "$dynload_dir/_ssl.cpython-312-darwin.so" "$absolute_ssl" '@loader_path/../../libssl.3.dylib'
  repair_dependency "$dynload_dir/_ssl.cpython-312-darwin.so" "$absolute_crypto" '@loader_path/../../libcrypto.3.dylib'
  repair_dependency "$dynload_dir/_hashlib.cpython-312-darwin.so" "$absolute_crypto" '@loader_path/../../libcrypto.3.dylib'
  repair_dependency "$framework_lib_dir/libssl.3.dylib" "$absolute_crypto" '@loader_path/libcrypto.3.dylib'
  if [[ -f "$framework_lib_dir/libssl.3.dylib" ]]; then
    install_name_tool -id '@loader_path/libssl.3.dylib' "$framework_lib_dir/libssl.3.dylib"
    codesign --force --sign - "$framework_lib_dir/libssl.3.dylib" >/dev/null 2>&1 || true
  fi
  if [[ -f "$framework_lib_dir/libcrypto.3.dylib" ]]; then
    install_name_tool -id '@loader_path/libcrypto.3.dylib' "$framework_lib_dir/libcrypto.3.dylib"
    codesign --force --sign - "$framework_lib_dir/libcrypto.3.dylib" >/dev/null 2>&1 || true
  fi
}

repair_bundled_python_install_names

install -m 755 \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/Resources/contora_mlx_server.py" \
  "$RUNTIME_ROOT/bin/contora_mlx_server.py"
install -m 644 \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/Resources/result_safety.py" \
  "$RUNTIME_ROOT/bin/result_safety.py"

if [[ -n "$PYANNOTE_ASSETS_SOURCE" ]]; then
  if [[ -d "$PYANNOTE_ASSETS_SOURCE/pyannote" ]]; then
    ditto "$PYANNOTE_ASSETS_SOURCE/pyannote" "$RUNTIME_ROOT/pyannote"
  else
    ditto "$PYANNOTE_ASSETS_SOURCE" "$RUNTIME_ROOT/pyannote"
  fi
else
  FETCH_ARGS=(--output "$RUNTIME_ROOT")
  if [[ -n "${HF_TOKEN_FILE:-}" ]]; then
    FETCH_ARGS+=(--token-file "$HF_TOKEN_FILE")
  fi
  "$SOURCE_VENV/bin/python" "$REPO_ROOT/tools/macos-whisper-runtime/fetch_pyannote.py" "${FETCH_ARGS[@]}"
fi

for asset in \
  speaker-diarization-3.1/config.yaml \
  segmentation-3.0/pytorch_model.bin \
  wespeaker-voxceleb-resnet34-LM/pytorch_model.bin; do
  if [[ ! -f "$RUNTIME_ROOT/pyannote/$asset" ]]; then
    echo "Required pyannote asset is missing: $asset" >&2
    exit 1
  fi
done

if [[ "$ENABLE_FLUID_ANE" == "1" ]]; then
  if [[ -z "$FLUID_MODELS_SOURCE" ]]; then
    echo "CONTORA_FLUID_MODELS_ROOT is required when CONTORA_SPEECH_INCLUDE_FLUID_ANE=1" >&2
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
  "schemaVersion": "2.0",
  "runtimeId": "speech-runtime",
  "mlxAudioVersion": "0.3.1",
  "pyannoteAudioVersion": "3.4.0",
  "platform": "macos",
  "architecture": "$(uname -m)",
  "pythonVersion": "$PYTHON_VERSION",
  "containsBundledPython": true,
  "containsPyannoteAssets": true,
  "fluidANEIncluded": $([[ "$ENABLE_FLUID_ANE" == "1" ]] && echo true || echo false),
  "fluidAudioVersion": $([[ "$ENABLE_FLUID_ANE" == "1" ]] && echo '"0.9.1"' || echo null),
  "fluidModelRevision": $([[ "$ENABLE_FLUID_ANE" == "1" ]] && echo '"'"$FLUID_MODEL_REVISION"'"' || echo null),
  "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

RUNTIME_PYTHON="$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION/bin/python$PYTHON_VERSION"
PYTHONHOME="$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION" \
PYTHONPATH="$RUNTIME_ROOT/venv/lib/python$PYTHON_VERSION/site-packages" \
  "$RUNTIME_PYTHON" -c 'import importlib.metadata as m; import fastapi, mlx, mlx_audio, pyannote.audio, torch, uvicorn; assert m.version("mlx-audio") == "0.3.1"; assert m.version("pyannote.audio") == "3.4.0"; assert m.version("fastapi") == "0.133.0"; assert m.version("uvicorn") == "0.41.0"'

tar -C "$BUILD_ROOT" -czf "$DIST_ROOT/$ARCHIVE_NAME" "$RUNTIME_NAME"
shasum -a 256 "$DIST_ROOT/$ARCHIVE_NAME" > "$DIST_ROOT/$ARCHIVE_NAME.sha256"
echo "$DIST_ROOT/$ARCHIVE_NAME"
