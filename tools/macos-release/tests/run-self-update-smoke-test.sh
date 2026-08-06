#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/contora-self-update-test.XXXXXX")"
TARGET_APP="$TEST_ROOT/installed/Contora.app"
STAGED_APP="$TEST_ROOT/staged/Contora.app"
ARCHIVE="$TEST_ROOT/Contora-macOS-0.6.3-arm64-unsigned.zip"
MARKER="${TMPDIR:-/tmp}/contora-self-update-smoke-passed"

cleanup() {
  rm -rf "$TEST_ROOT"
  rm -f "$MARKER"
}
trap cleanup EXIT

make_bundle() {
  local app_path="$1"
  local version="$2"
  mkdir -p "$app_path/Contents/MacOS"
  plutil -create xml1 "$app_path/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string ai.niketas.contora "$app_path/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string Contora "$app_path/Contents/Info.plist"
  plutil -insert CFBundlePackageType -string APPL "$app_path/Contents/Info.plist"
  plutil -insert CFBundleShortVersionString -string "$version" "$app_path/Contents/Info.plist"
  plutil -insert CFBundleVersion -string "$version" "$app_path/Contents/Info.plist"
}

make_bundle "$TARGET_APP" 0.6.2
make_bundle "$STAGED_APP" 0.6.3

swiftc -parse-as-library \
  "$REPO_ROOT/apps/macos/Sources/ContoraMac/SelfUpdateInstaller.swift" \
  "$SCRIPT_DIR/SelfUpdateHarness.swift" \
  -o "$TARGET_APP/Contents/MacOS/Contora"
swiftc -parse-as-library \
  "$SCRIPT_DIR/UpdatedAppMarker.swift" \
  -o "$STAGED_APP/Contents/MacOS/Contora"

codesign --force --deep --sign - "$TARGET_APP"
codesign --force --deep --sign - "$STAGED_APP"
ditto --noextattr --norsrc -c -k --keepParent "$STAGED_APP" "$ARCHIVE"

"$TARGET_APP/Contents/MacOS/Contora" "$ARCHIVE" 0.6.3

for _ in {1..100}; do
  if [[ -f "$MARKER" ]] && \
     ! find "$TEST_ROOT/installed" -maxdepth 1 -name '.Contora-update-backup-*.app' | grep -q .; then
    break
  fi
  sleep 0.1
done

if [[ ! -f "$MARKER" ]]; then
  echo "Updated app did not launch" >&2
  exit 1
fi

installed_version="$(plutil -extract CFBundleShortVersionString raw "$TARGET_APP/Contents/Info.plist")"
if [[ "$installed_version" != "0.6.3" ]]; then
  echo "Expected installed version 0.6.3, found $installed_version" >&2
  exit 1
fi

if find "$TEST_ROOT/installed" -maxdepth 1 -name '.Contora-update-backup-*.app' | grep -q .; then
  echo "Updater backup was not cleaned up" >&2
  exit 1
fi

echo "Self-update smoke test passed"
