#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDECAR_ROOT="$REPO_ROOT/tools/vk-asr-server"
ENV_FILE="${CONTORA_VK_ENV_FILE:-$SIDECAR_ROOT/.env}"
ROOT_ENV_FILE="${CONTORA_CORPORATE_ENV_FILE:-$REPO_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Corporate configuration is missing: $ENV_FILE" >&2
  echo "Create it from $SIDECAR_ROOT/.env.example and add SPEECH_API_TOKEN." >&2
  exit 1
fi

TOKEN_OVERRIDE="${SPEECH_API_TOKEN:-}"
set -a
source "$ENV_FILE"
if [[ -f "$ROOT_ENV_FILE" ]]; then
  source "$ROOT_ENV_FILE"
fi
set +a
if [[ -n "$TOKEN_OVERRIDE" ]]; then
  export SPEECH_API_TOKEN="$TOKEN_OVERRIDE"
fi

if [[ -z "${SPEECH_API_TOKEN:-}" ]]; then
  LIGHTNINGASR_ENV="${LIGHTNINGASR_ENV_FILE:-/Users/n.likhachev/Documents/projects/lightningasr/.env}"
  if [[ -f "$LIGHTNINGASR_ENV" ]]; then
    LEGACY_TOKEN="$(
      set +u
      SPEECH_API_TOKEN=""
      source "$LIGHTNINGASR_ENV" >/dev/null 2>&1
      printf '%s' "${SPEECH_API_TOKEN:-}"
    )"
    if [[ -n "$LEGACY_TOKEN" ]]; then
      export SPEECH_API_TOKEN="$LEGACY_TOKEN"
    fi
  fi
fi

MISSING_VALUES=()
[[ -n "${SPEECH_API_BASE_URL:-}" ]] || MISSING_VALUES+=("SPEECH_API_BASE_URL")
[[ -n "${SPEECH_API_TOKEN:-}" ]] || MISSING_VALUES+=("SPEECH_API_TOKEN")
[[ -n "${CONTORA_VK_UPLOAD_BASE_URL:-}" ]] || MISSING_VALUES+=("CONTORA_VK_UPLOAD_BASE_URL")
if (( ${#MISSING_VALUES[@]} > 0 )); then
  echo "Missing corporate configuration: ${MISSING_VALUES[*]}" >&2
  echo "Checked $ROOT_ENV_FILE, $ENV_FILE, and the LightningASR token fallback." >&2
  exit 1
fi

SIDECAR_PORT="${CONTORA_VK_PORT:-8020}"
SIDECAR_HEALTH_URL="http://127.0.0.1:$SIDECAR_PORT/health"
SIDECAR_READY_URL="http://127.0.0.1:$SIDECAR_PORT/ready"
export CONTORA_TRANSCRIPTION_JOB_ENDPOINT="http://127.0.0.1:$SIDECAR_PORT/v1/audio/transcriptions"
export CONTORA_TRANSCRIPTION_DIARIZATION="${CONTORA_TRANSCRIPTION_DIARIZATION:-true}"
export CONTORA_TRANSCRIPTION_MODEL="${SPEECH_API_MODEL:-latest}"

LOG_ROOT="$HOME/Library/Logs/ContoraCorporate"
LOG_PATH="$LOG_ROOT/vk-asr-server.log"
mkdir -p "$LOG_ROOT"

SIDECAR_PID=""
cleanup() {
  if [[ -n "$SIDECAR_PID" ]] && kill -0 "$SIDECAR_PID" 2>/dev/null; then
    kill "$SIDECAR_PID" 2>/dev/null || true
    wait "$SIDECAR_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if ! curl -fsS "$SIDECAR_HEALTH_URL" >/dev/null 2>&1; then
  CONTORA_VK_SKIP_ENV_FILE=1 "$SIDECAR_ROOT/run-server.sh" >"$LOG_PATH" 2>&1 &
  SIDECAR_PID=$!
  for _ in {1..60}; do
    if curl -fsS "$SIDECAR_HEALTH_URL" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$SIDECAR_PID" 2>/dev/null; then
      echo "Corporate ASR sidecar exited during startup. Log: $LOG_PATH" >&2
      tail -n 40 "$LOG_PATH" >&2 || true
      exit 1
    fi
    sleep 0.25
  done
fi

if ! curl -fsS "$SIDECAR_HEALTH_URL" >/dev/null 2>&1; then
  echo "Corporate ASR sidecar did not become ready. Log: $LOG_PATH" >&2
  exit 1
fi

READY_RESPONSE="$(curl -sS "$SIDECAR_READY_URL" || true)"
if ! curl -fsS "$SIDECAR_READY_URL" >/dev/null 2>&1; then
  echo "Corporate ASR sidecar is running but not configured: $READY_RESPONSE" >&2
  echo "Configuration sources: $ROOT_ENV_FILE and $ENV_FILE" >&2
  exit 1
fi

echo "Corporate ASR sidecar is ready: $SIDECAR_READY_URL"
if [[ "${CONTORA_CORPORATE_PREFLIGHT_ONLY:-0}" == "1" ]]; then
  echo "Corporate launch preflight completed successfully."
  exit 0
fi
echo "Launching Contora Corporate..."
swift run --package-path "$REPO_ROOT/apps/macos" ContoraMac
