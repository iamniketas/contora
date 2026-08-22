#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MACOS_DIR="$REPO_ROOT/apps/macos"
ARTIFACT_ROOT="${CONTORA_MACOS_ARTIFACT_ROOT:-$REPO_ROOT/artifacts/macos-pilot}"
APP_NAME="${CONTORA_MACOS_APP_NAME:-Contora}"
BUNDLE_ID="${CONTORA_MACOS_BUNDLE_ID:-ai.niketas.contora}"
VERSION="${CONTORA_VERSION:-$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')}"
ARCH="$(uname -m)"
BUILD_ROOT="${CONTORA_MACOS_BUILD_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/contora-macos-pilot.XXXXXX")}"
PUBLISH_APP_DIR="$ARTIFACT_ROOT/$APP_NAME.app"
CODE_SIGN_IDENTITY="${CONTORA_MACOS_SIGN_IDENTITY:--}"
CREATE_DMG="${CONTORA_MACOS_CREATE_DMG:-1}"
NOTARIZE="${CONTORA_MACOS_NOTARIZE:-0}"
NOTARY_PROFILE="${CONTORA_MACOS_NOTARY_PROFILE:-}"
BUNDLE_SHORT_VERSION="${CONTORA_MACOS_BUNDLE_SHORT_VERSION:-$(printf '%s' "$VERSION" | sed -E 's/^([0-9]+(\.[0-9]+){0,2}).*/\1/')}"
BUNDLE_BUILD_VERSION="${CONTORA_MACOS_BUNDLE_VERSION:-$(printf '%s' "$VERSION" | tr -cs '[:alnum:].-' '.')}"
SIGNING_LABEL="unsigned"
if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
  SIGNING_LABEL="signed"
fi
if [[ -z "$BUNDLE_SHORT_VERSION" || ! "$BUNDLE_SHORT_VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  BUNDLE_SHORT_VERSION="0.0.0"
fi
if [[ -z "$BUNDLE_BUILD_VERSION" ]]; then
  BUNDLE_BUILD_VERSION="$BUNDLE_SHORT_VERSION"
fi

APP_DIR="$BUILD_ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_CONTENTS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
STAGING_DIR="$BUILD_ROOT/staging"
ZIP_PATH="$ARTIFACT_ROOT/${APP_NAME}-macOS-${VERSION}-${ARCH}-${SIGNING_LABEL}.zip"
DMG_PATH="$ARTIFACT_ROOT/${APP_NAME}-macOS-${VERSION}-${ARCH}-${SIGNING_LABEL}.dmg"
DMG_RW_PATH="$BUILD_ROOT/${APP_NAME}-macOS-${VERSION}-${ARCH}-${SIGNING_LABEL}-rw.dmg"
DMG_MOUNT_DIR="$BUILD_ROOT/dmg-mount"

rm -rf "$BUILD_ROOT" "$PUBLISH_APP_DIR" "$ZIP_PATH" "$DMG_PATH" "$DMG_RW_PATH" "$DMG_MOUNT_DIR"
mkdir -p "$MACOS_CONTENTS_DIR" "$RESOURCES_DIR" "$STAGING_DIR"

clear_extended_attributes() {
  local path="$1"
  xattr -cr "$path" 2>/dev/null || true
  find "$path" -exec xattr -c {} \; 2>/dev/null || true
}

sign_app() {
  local app_path="$1"
  if ! command -v codesign >/dev/null 2>&1; then
    return
  fi

  clear_extended_attributes "$app_path"
  local args=(--force --deep --sign "$CODE_SIGN_IDENTITY")
  if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
    args+=(--options runtime --timestamp)
  fi
  codesign "${args[@]}" "$app_path"
}

swift build -c release --package-path "$MACOS_DIR"
BIN_PATH="$(swift build -c release --package-path "$MACOS_DIR" --show-bin-path)"

install -m 755 "$BIN_PATH/ContoraMac" "$MACOS_CONTENTS_DIR/$APP_NAME"

if [[ -d "$BIN_PATH/ContoraMac_ContoraMac.bundle" ]]; then
  ditto "$BIN_PATH/ContoraMac_ContoraMac.bundle" "$RESOURCES_DIR/ContoraMac_ContoraMac.bundle"
fi

RUNTIME_ARCHIVE="${CONTORA_MACOS_SPEECH_RUNTIME_ARCHIVE:-}"
BUNDLE_SPEECH_RUNTIME="${CONTORA_MACOS_BUNDLE_SPEECH_RUNTIME:-0}"
if [[ -z "$RUNTIME_ARCHIVE" && "$BUNDLE_SPEECH_RUNTIME" == "1" ]]; then
  CANDIDATE="$REPO_ROOT/artifacts/macos-speech-runtime/dist/ContoraMacSpeechRuntime-${ARCH}.tar.gz"
  if [[ -f "$CANDIDATE" ]]; then
    RUNTIME_ARCHIVE="$CANDIDATE"
  fi
fi

if [[ -n "$RUNTIME_ARCHIVE" ]]; then
  install -m 644 "$RUNTIME_ARCHIVE" "$RESOURCES_DIR/ContoraMacSpeechRuntime-${ARCH}.tar.gz"
  if [[ -f "$RUNTIME_ARCHIVE.sha256" ]]; then
    install -m 644 "$RUNTIME_ARCHIVE.sha256" "$RESOURCES_DIR/ContoraMacSpeechRuntime-${ARCH}.tar.gz.sha256"
  fi
fi

SOURCE_ICON="$REPO_ROOT/src/AudioRecorder.App/Assets/source_icon.png"
if [[ -f "$SOURCE_ICON" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$ARTIFACT_ROOT/Contora.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/Contora.icns"
  rm -rf "$ICONSET"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Contora</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Contora</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Contora</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_SHORT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_BUILD_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Contora records microphone audio when you start a local recording.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Contora uses Screen Recording permission to capture system audio locally.</string>
</dict>
</plist>
PLIST

sign_app "$APP_DIR"

ditto --noextattr --norsrc "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/OPEN_ME_FIRST.txt" <<README
Contora macOS Pilot
===================

Build: ${VERSION} (${ARCH}, ${SIGNING_LABEL})

First launch:
1. Move Contora.app to Applications.
2. Open Contora.app.
3. If macOS blocks it, open System Settings -> Privacy & Security.
4. Click Open Anyway for Contora, then confirm Open.

Managed speech backend:
- Press Set Up Speech Runtime inside Contora once.
- If this archive contains ContoraMacSpeechRuntime-${ARCH}.tar.gz, setup installs it locally.
- Otherwise Contora downloads the self-contained runtime from the latest GitHub release.
- The backend starts automatically for a transcription job and stops after an idle timeout.

All recordings, models, and transcripts stay on this Mac.
README

ditto --noextattr --norsrc -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

if [[ "$CREATE_DMG" == "1" ]]; then
  mkdir -p "$DMG_MOUNT_DIR"
  hdiutil create -quiet -size "${CONTORA_MACOS_DMG_SIZE:-1100m}" -fs APFS -volname "Contora ${VERSION}" -type UDIF -ov "$DMG_RW_PATH"
  hdiutil attach "$DMG_RW_PATH" -mountpoint "$DMG_MOUNT_DIR" -nobrowse -quiet
  cleanup_dmg_mount() {
    hdiutil detach "$DMG_MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  }
  trap cleanup_dmg_mount EXIT

  ditto --noextattr --norsrc "$APP_DIR" "$DMG_MOUNT_DIR/$APP_NAME.app"
  ln -s /Applications "$DMG_MOUNT_DIR/Applications"
  cat > "$DMG_MOUNT_DIR/OPEN_ME_FIRST.txt" <<README
Contora macOS Pilot
===================

Build: ${VERSION} (${ARCH}, ${SIGNING_LABEL})

First launch:
1. Drag Contora.app to Applications.
2. Open Contora.app.
3. If macOS blocks it, open System Settings -> Privacy & Security.
4. Click Open Anyway for Contora, then confirm Open.

Managed speech backend:
- Press Set Up Speech Runtime inside Contora once.
- If setup fails, use Backend -> Set Up Speech Runtime again and open the runtime log.
README

  sign_app "$DMG_MOUNT_DIR/$APP_NAME.app"
  codesign --verify --deep --strict --verbose=2 "$DMG_MOUNT_DIR/$APP_NAME.app"

  hdiutil detach "$DMG_MOUNT_DIR" -quiet
  trap - EXIT
  hdiutil convert "$DMG_RW_PATH" -quiet -format UDZO -o "$DMG_PATH"
  rm -f "$DMG_RW_PATH"

  if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH"
  fi

  if [[ "$NOTARIZE" == "1" ]]; then
    if [[ -z "$NOTARY_PROFILE" ]]; then
      echo "CONTORA_MACOS_NOTARY_PROFILE is required when CONTORA_MACOS_NOTARIZE=1" >&2
      exit 1
    fi
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
  fi

  hdiutil attach "$DMG_PATH" -mountpoint "$DMG_MOUNT_DIR" -nobrowse -quiet
  trap cleanup_dmg_mount EXIT
  codesign --verify --deep --strict --verbose=2 "$DMG_MOUNT_DIR/$APP_NAME.app"
  hdiutil detach "$DMG_MOUNT_DIR" -quiet
  trap - EXIT
  rm -rf "$DMG_MOUNT_DIR"
elif [[ "$NOTARIZE" == "1" ]]; then
  echo "CONTORA_MACOS_CREATE_DMG=1 is required for notarized macOS releases" >&2
  exit 1
fi

if [[ -f "$DMG_PATH" ]]; then
  shasum -a 256 "$ZIP_PATH" "$DMG_PATH" > "$ARTIFACT_ROOT/SHA256SUMS"
else
  shasum -a 256 "$ZIP_PATH" > "$ARTIFACT_ROOT/SHA256SUMS"
fi

ditto --noextattr --norsrc "$APP_DIR" "$PUBLISH_APP_DIR"

echo "App: $PUBLISH_APP_DIR"
echo "ZIP: $ZIP_PATH"
if [[ -f "$DMG_PATH" ]]; then
  echo "DMG: $DMG_PATH"
fi
echo "SHA256: $ARTIFACT_ROOT/SHA256SUMS"
