#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/ContoraMacSpeechRuntime-arm64.tar.gz" >&2
  exit 2
fi

ARCHIVE="$1"
[[ -f "$ARCHIVE" ]] || { echo "Runtime archive not found: $ARCHIVE" >&2; exit 1; }
VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/contora-speech-runtime-verify.XXXXXX")"
runtime_server_pid=""
cleanup_verify_root() {
  if [[ -n "$runtime_server_pid" ]]; then
    kill "$runtime_server_pid" >/dev/null 2>&1 || true
    wait "$runtime_server_pid" >/dev/null 2>&1 || true
  fi
  find "$VERIFY_ROOT" -depth -delete
}
trap cleanup_verify_root EXIT
tar -xzf "$ARCHIVE" -C "$VERIFY_ROOT"
RUNTIME_ROOT="$VERIFY_ROOT/speech-runtime"
PYTHON_VERSION="3.12"
PYTHON="$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION/bin/python$PYTHON_VERSION"
SITE_PACKAGES="$RUNTIME_ROOT/venv/lib/python$PYTHON_VERSION/site-packages"

for required in \
  "$PYTHON" \
  "$RUNTIME_ROOT/bin/contora_mlx_server.py" \
  "$RUNTIME_ROOT/bin/result_safety.py" \
  "$RUNTIME_ROOT/runtime-manifest.json" \
  "$RUNTIME_ROOT/pyannote/speaker-diarization-3.1/config.yaml" \
  "$RUNTIME_ROOT/pyannote/segmentation-3.0/pytorch_model.bin" \
  "$RUNTIME_ROOT/pyannote/wespeaker-voxceleb-resnet34-LM/pytorch_model.bin" \
  "$SITE_PACKAGES/mlx_audio" \
  "$SITE_PACKAGES/mlx" \
  "$SITE_PACKAGES/pyannote" \
  "$SITE_PACKAGES/torch"; do
  [[ -e "$required" ]] || { echo "Runtime entry missing: $required" >&2; exit 1; }
done

if tar -tzf "$ARCHIVE" | grep -Fq 'faster-whisper-xxl'; then
  echo "Legacy faster-whisper runtime must not be present in the speech runtime archive" >&2
  exit 1
fi

PYTHONHOME="$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION" \
PYTHONPATH="$SITE_PACKAGES" \
  "$PYTHON" -c 'import importlib.metadata as m; import fastapi, json, mlx, mlx_audio, pyannote.audio, torch, uvicorn; manifest=json.load(open("'"$RUNTIME_ROOT/runtime-manifest.json"'")); assert manifest["runtimeId"] == "speech-runtime"; assert manifest["containsBundledPython"] is True; assert manifest["containsPyannoteAssets"] is True; assert m.version("mlx-audio") == manifest["mlxAudioVersion"]; assert m.version("pyannote.audio") == manifest["pyannoteAudioVersion"]'

VERIFY_PORT="$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
PYTHONHOME="$RUNTIME_ROOT/python/Python.framework/Versions/$PYTHON_VERSION" \
PYTHONPATH="$SITE_PACKAGES" \
CONTORA_SPEECH_RUNTIME_ROOT="$RUNTIME_ROOT" \
CONTORA_MLX_RESULTS_ROOT="$VERIFY_ROOT/results" \
CONTORA_MLX_HANDOFF_ROOT="$VERIFY_ROOT/handoff" \
CONTORA_MLX_PORT="$VERIFY_PORT" \
CONTORA_MLX_IDLE_SHUTDOWN_SECONDS=0 \
  "$PYTHON" "$RUNTIME_ROOT/bin/contora_mlx_server.py" >"$VERIFY_ROOT/server.log" 2>&1 &
runtime_server_pid="$!"

health_payload=""
for _ in {1..120}; do
  if health_payload="$(/usr/bin/curl -fsS --max-time 1 "http://127.0.0.1:$VERIFY_PORT/health" 2>/dev/null)"; then
    break
  fi
  if ! kill -0 "$runtime_server_pid" 2>/dev/null; then
    cat "$VERIFY_ROOT/server.log" >&2
    echo "Speech runtime server exited before health check" >&2
    exit 1
  fi
  sleep 0.5
done
if [[ -z "$health_payload" ]] || ! printf '%s' "$health_payload" | /usr/bin/python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["status"] == "ok"; assert value["activeJobs"] == 0'; then
  cat "$VERIFY_ROOT/server.log" >&2
  echo "Speech runtime health check failed" >&2
  exit 1
fi
kill "$runtime_server_pid"
wait "$runtime_server_pid" 2>/dev/null || true
runtime_server_pid=""

echo "Speech runtime archive verified: $ARCHIVE"
