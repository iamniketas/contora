#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_ROOT="${CONTORA_MACOS_ARTIFACT_ROOT:-$REPO_ROOT/artifacts/macos-pilot}"
SPEECH_RUNTIME_DIST="${CONTORA_SPEECH_DIST_ROOT:-$REPO_ROOT/artifacts/macos-speech-runtime/dist}"
REPO="${CONTORA_GITHUB_REPO:-iamniketas/contora}"
TAG="${CONTORA_RELEASE_TAG:-v${CONTORA_VERSION:-0.5.2-macos-pilot}}"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "GITHUB_TOKEN is required. Create a token with repo contents write access, then rerun." >&2
  exit 1
fi

api() {
  curl -fsS \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

release_json="$(mktemp "${TMPDIR:-/tmp}/contora-release.XXXXXX.json")"
api "https://api.github.com/repos/$REPO/releases/tags/$TAG" > "$release_json"
release_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$release_json")"
upload_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upload_url"].split("{",1)[0])' "$release_json")"

delete_existing_asset() {
  local name="$1"
  local asset_id
  asset_id="$(python3 - "$release_json" "$name" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
name = sys.argv[2]
for asset in release.get("assets", []):
    if asset.get("name") == name:
        print(asset["id"])
        break
PY
)"
  if [[ -n "$asset_id" ]]; then
    api -X DELETE "https://api.github.com/repos/$REPO/releases/assets/$asset_id" >/dev/null
    echo "Deleted existing asset: $name"
  fi
}

upload_asset() {
  local path="$1"
  local content_type="$2"
  local name
  name="$(basename "$path")"
  delete_existing_asset "$name"
  api \
    -X POST \
    -H "Content-Type: $content_type" \
    --data-binary "@$path" \
    "$upload_url?name=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$name")" >/dev/null
  echo "Uploaded asset: $name"
}

shopt -s nullglob
runtime_archives=("$SPEECH_RUNTIME_DIST"/ContoraMacSpeechRuntime-*.tar.gz)
if [[ ${#runtime_archives[@]} -eq 0 && "${CONTORA_RELEASE_SKIP_SPEECH_RUNTIME:-0}" != "1" ]]; then
  echo "Speech runtime artifact is required before publishing: $SPEECH_RUNTIME_DIST" >&2
  exit 1
fi
for dmg in "$ARTIFACT_ROOT"/Contora-macOS-*-unsigned.dmg "$ARTIFACT_ROOT"/Contora-macOS-*-signed.dmg; do
  upload_asset "$dmg" "application/x-apple-diskimage"
done
for zip in "$ARTIFACT_ROOT"/Contora-macOS-*-unsigned.zip "$ARTIFACT_ROOT"/Contora-macOS-*-signed.zip; do
  upload_asset "$zip" "application/zip"
done
for runtime in "${runtime_archives[@]}"; do
  "$REPO_ROOT/tools/macos-mlx-runtime/verify-runtime-archive.sh" "$runtime"
  upload_asset "$runtime" "application/gzip"
  if [[ -f "$runtime.sha256" ]]; then
    upload_asset "$runtime.sha256" "text/plain"
  fi
done
if [[ -f "$ARTIFACT_ROOT/SHA256SUMS" ]]; then
  upload_asset "$ARTIFACT_ROOT/SHA256SUMS" "text/plain"
fi

echo "Release updated: https://github.com/$REPO/releases/tag/$TAG"
