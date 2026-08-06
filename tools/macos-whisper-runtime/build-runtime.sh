#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="${CONTORA_RUNTIME_BUILD_ROOT:-$REPO_ROOT/artifacts/macos-whisper-runtime/build}"
DIST_ROOT="${CONTORA_RUNTIME_DIST_ROOT:-$REPO_ROOT/artifacts/macos-whisper-runtime/dist}"
RUNTIME_NAME="faster-whisper-xxl"
RUNTIME_ROOT="$BUILD_ROOT/$RUNTIME_NAME"
PYTHON_BIN="${PYTHON_BIN:-python3}"
ARCHIVE_NAME="${CONTORA_RUNTIME_ARCHIVE_NAME:-ContoraMacWhisperRuntime-$(uname -m).tar.gz}"

rm -rf "$BUILD_ROOT" "$DIST_ROOT"
mkdir -p "$RUNTIME_ROOT/bin" "$DIST_ROOT"

"$SCRIPT_DIR/sync-app-script.sh"

PYTHON_EXECUTABLE="$("$PYTHON_BIN" -c 'import sys; print(sys.executable)')"
PYTHON_VERSION="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PYTHON_PREFIX="$("$PYTHON_BIN" -c 'import sys; print(sys.prefix)')"

"$PYTHON_BIN" -m venv "$RUNTIME_ROOT/venv"
"$RUNTIME_ROOT/venv/bin/python" -m pip install --upgrade pip setuptools wheel
"$RUNTIME_ROOT/venv/bin/python" -m pip install --upgrade -r "$SCRIPT_DIR/requirements.txt"

install -m 755 "$SCRIPT_DIR/contora_fw_transcribe.py" "$RUNTIME_ROOT/bin/contora_fw_transcribe.py"

if [[ -d "$PYTHON_PREFIX" ]]; then
  mkdir -p "$RUNTIME_ROOT/python"
  ditto "$PYTHON_PREFIX" "$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION"
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

  if ! command -v install_name_tool >/dev/null 2>&1; then
    return
  fi

  if [[ -x "$python_bin" ]]; then
    install_name_tool -change "$absolute_ref" "@executable_path/../Python" "$python_bin" || true
    codesign --force --sign - "$python_bin" >/dev/null 2>&1 || true
  fi

  if [[ -x "$python_app_bin" ]]; then
    install_name_tool -change "$absolute_ref" "@executable_path/../../../../Python" "$python_app_bin" || true
    codesign --force --sign - "$python_app_bin" >/dev/null 2>&1 || true
  fi

  if [[ -f "$framework_lib" ]]; then
    codesign --force --sign - "$framework_lib" >/dev/null 2>&1 || true
  fi

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
  install_name_tool -id '@loader_path/libssl.3.dylib' "$framework_lib_dir/libssl.3.dylib"
  install_name_tool -id '@loader_path/libcrypto.3.dylib' "$framework_lib_dir/libcrypto.3.dylib"
  codesign --force --sign - "$framework_lib_dir/libssl.3.dylib" >/dev/null 2>&1 || true
  codesign --force --sign - "$framework_lib_dir/libcrypto.3.dylib" >/dev/null 2>&1 || true
}

repair_bundled_python_install_names

cat > "$RUNTIME_ROOT/$RUNTIME_NAME" <<'EOF'
#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
PYTHON_VERSION="${CONTORA_RUNTIME_PYTHON_VERSION:-3.12}"
BUNDLED_PYTHON_HOME="$ROOT/python/Python.framework/Versions/$PYTHON_VERSION"
BUNDLED_PYTHON="$BUNDLED_PYTHON_HOME/bin/python$PYTHON_VERSION"
if [ -x "$BUNDLED_PYTHON" ]; then
  export PYTHONHOME="$BUNDLED_PYTHON_HOME"
  export PYTHONPATH="$ROOT/venv/lib/python$PYTHON_VERSION/site-packages${PYTHONPATH:+:$PYTHONPATH}"
  exec "$BUNDLED_PYTHON" "$ROOT/bin/contora_fw_transcribe.py" "$@"
fi

if [ -x "$ROOT/venv/bin/python" ]; then
  exec "$ROOT/venv/bin/python" "$ROOT/bin/contora_fw_transcribe.py" "$@"
fi

exec python3 "$ROOT/bin/contora_fw_transcribe.py" "$@"
EOF
chmod +x "$RUNTIME_ROOT/$RUNTIME_NAME"

if [[ "${CONTORA_INCLUDE_PYANNOTE:-1}" == "1" ]]; then
  if [[ -n "${HF_TOKEN_FILE:-}" ]]; then
    "$RUNTIME_ROOT/venv/bin/python" "$SCRIPT_DIR/fetch_pyannote.py" --output "$RUNTIME_ROOT" --token-file "$HF_TOKEN_FILE"
  else
    "$RUNTIME_ROOT/venv/bin/python" "$SCRIPT_DIR/fetch_pyannote.py" --output "$RUNTIME_ROOT"
  fi
  find "$RUNTIME_ROOT/pyannote" -type d -name .cache -prune -exec rm -rf {} +
fi

cat > "$RUNTIME_ROOT/runtime-manifest.json" <<EOF
{
  "schemaVersion": "1.0",
  "runtimeId": "faster-whisper-xxl",
  "platform": "macos",
  "architecture": "$(uname -m)",
  "pythonVersion": "$PYTHON_VERSION",
  "containsBundledPython": $([[ -x "$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION/bin/python$PYTHON_VERSION" ]] && echo true || echo false),
  "containsPyannoteAssets": $([[ -d "$RUNTIME_ROOT/pyannote/speaker-diarization-3.1" ]] && echo true || echo false),
  "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

tar -C "$BUILD_ROOT" -czf "$DIST_ROOT/$ARCHIVE_NAME" "$RUNTIME_NAME"
shasum -a 256 "$DIST_ROOT/$ARCHIVE_NAME" > "$DIST_ROOT/$ARCHIVE_NAME.sha256"

echo "$DIST_ROOT/$ARCHIVE_NAME"
