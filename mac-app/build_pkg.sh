#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_DIR=${BUILD_DIR:-"$SCRIPT_DIR/build"}
APP_DIR="$BUILD_DIR/Whisper Mac.app"
CONTENTS_DIR="$APP_DIR/Contents"
PKG_ROOT="$BUILD_DIR/pkgroot"

rm -rf "$BUILD_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources/python" "$PKG_ROOT/Applications"
mkdir -p "$BUILD_DIR/module-cache"

xcrun swiftc \
  -swift-version 5 \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -O \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework Security \
  "$SCRIPT_DIR/Sources/WhisperMacApp.swift" \
  -o "$CONTENTS_DIR/MacOS/WhisperMac"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
ditto --norsrc --noextattr "$PROJECT_DIR/mac-cli/src/whisper_mac_cli" "$CONTENTS_DIR/Resources/python/whisper_mac_cli"
find "$CONTENTS_DIR/Resources/python" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$CONTENTS_DIR/Resources/python" -type f -name '*.pyc' -delete

codesign --force --deep --sign - "$APP_DIR"
ditto --norsrc --noextattr "$APP_DIR" "$PKG_ROOT/Applications/Whisper Mac.app"
xattr -cr "$PKG_ROOT"
find "$PKG_ROOT" -type f -name '._*' -delete

COPYFILE_DISABLE=1 pkgbuild \
  --root "$PKG_ROOT" \
  --component-plist "$SCRIPT_DIR/Component.plist" \
  --identifier com.whispermac.pkg \
  --version 0.3.0 \
  --install-location / \
  "$BUILD_DIR/WhisperMac-0.3.0.pkg"

echo "$BUILD_DIR/WhisperMac-0.3.0.pkg"
