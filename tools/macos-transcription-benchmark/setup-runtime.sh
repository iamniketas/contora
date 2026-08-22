#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
RUNTIME_ROOT="${CONTORA_BENCH_RUNTIME_ROOT:-$SCRIPT_DIR/.runtime}"
PYTHON_BIN="${CONTORA_BENCH_BOOTSTRAP_PYTHON:-python3}"

mkdir -p "$RUNTIME_ROOT/sources" "$RUNTIME_ROOT/models"

clone_exact() {
  local url="$1"
  local tag="$2"
  local expected="$3"
  local destination="$4"
  if [[ ! -d "$destination/.git" ]]; then
    git clone --depth 1 --branch "$tag" "$url" "$destination"
  fi
  local actual
  actual="$(git -C "$destination" rev-parse HEAD)"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "Pinned source mismatch for $destination: expected $expected, got $actual"
    exit 2
  fi
}

clone_exact \
  https://github.com/argmaxinc/argmax-oss-swift.git \
  v1.1.0 \
  1e2a163736dfa5a198e637ae44c114e1c6d5cc2d \
  "$RUNTIME_ROOT/sources/argmax-oss-swift"

swift build --package-path "$RUNTIME_ROOT/sources/argmax-oss-swift" -c release --product argmax-cli
swift build --package-path "$SCRIPT_DIR/native" -c release --product contora-fluid-diarize \
  -Xswiftc -swift-version -Xswiftc 5

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1 && [[ ! -x "$PYTHON_BIN" ]]; then
  print -u2 "Python not found: $PYTHON_BIN. Set CONTORA_BENCH_BOOTSTRAP_PYTHON."
  exit 2
fi
if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
  print -u2 "Python 3.11 or newer is required. Set CONTORA_BENCH_BOOTSTRAP_PYTHON."
  exit 2
fi
if [[ ! -x "$RUNTIME_ROOT/python/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$RUNTIME_ROOT/python"
fi
"$RUNTIME_ROOT/python/bin/python" -m pip install --upgrade pip
"$RUNTIME_ROOT/python/bin/python" -m pip install -r "$SCRIPT_DIR/requirements.txt"

if [[ ! -x "$RUNTIME_ROOT/pyannote-community-python/bin/python" ]]; then
  "$PYTHON_BIN" -m venv "$RUNTIME_ROOT/pyannote-community-python"
fi
"$RUNTIME_ROOT/pyannote-community-python/bin/python" -m pip install --upgrade pip
"$RUNTIME_ROOT/pyannote-community-python/bin/python" -m pip install \
  -r "$SCRIPT_DIR/requirements-community.txt"

print "Runtime ready: $RUNTIME_ROOT"
print "Download pinned models with: $RUNTIME_ROOT/python/bin/python $SCRIPT_DIR/download-models.py --root $RUNTIME_ROOT/models"
