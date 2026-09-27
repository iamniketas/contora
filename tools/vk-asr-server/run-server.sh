#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CONTORA_VK_ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ "${CONTORA_VK_SKIP_ENV_FILE:-0}" != "1" && ! -f "$ENV_FILE" ]]; then
  echo "Missing private configuration: $ENV_FILE" >&2
  echo "Copy .env.example to .env and fill it on the corporate machine." >&2
  exit 1
fi

if [[ "${CONTORA_VK_SKIP_ENV_FILE:-0}" != "1" ]]; then
  TOKEN_OVERRIDE="${SPEECH_API_TOKEN:-}"
  set -a
  source "$ENV_FILE"
  set +a
  if [[ -n "$TOKEN_OVERRIDE" ]]; then
    export SPEECH_API_TOKEN="$TOKEN_OVERRIDE"
  fi
fi

DEFAULT_RUNTIME_ROOT="$HOME/Library/Application Support/NiketasAI/runtime/speech-runtime"
RUNTIME_ROOT="${CONTORA_SPEECH_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
BUNDLED_PYTHON="$RUNTIME_ROOT/python/Python.framework/Versions/3.12/bin/python3.12"
BUNDLED_SITE_PACKAGES="$RUNTIME_ROOT/venv/lib/python3.12/site-packages"

if [[ -n "${CONTORA_VK_PYTHON:-}" ]]; then
  PYTHON_EXECUTABLE="$CONTORA_VK_PYTHON"
elif [[ -x "$BUNDLED_PYTHON" && -d "$BUNDLED_SITE_PACKAGES" ]]; then
  PYTHON_EXECUTABLE="$BUNDLED_PYTHON"
  export CONTORA_SPEECH_RUNTIME_ROOT="$RUNTIME_ROOT"
  export PYTHONHOME="$RUNTIME_ROOT/python/Python.framework/Versions/3.12"
  export PYTHONPATH="$SCRIPT_DIR/src:$BUNDLED_SITE_PACKAGES${PYTHONPATH:+:$PYTHONPATH}"
else
  PYTHON_EXECUTABLE="python3"
  export PYTHONPATH="$SCRIPT_DIR/src${PYTHONPATH:+:$PYTHONPATH}"
fi

exec "$PYTHON_EXECUTABLE" -m contora_vk_server.server
