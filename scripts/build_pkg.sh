#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_SOURCE_DIR="$PROJECT_DIR/app"
CLI_SOURCE_DIR="$PROJECT_DIR/cli"
BUILD_DIR=${BUILD_DIR:-"$PROJECT_DIR/build"}
APP_DIR="$BUILD_DIR/Whisper Mac.app"
CONTENTS_DIR="$APP_DIR/Contents"
PKG_ROOT="$BUILD_DIR/pkgroot"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SOURCE_DIR/Info.plist")
PKG_PATH="$BUILD_DIR/WhisperMac-$VERSION.pkg"
APP_SIGN_IDENTITY=${APP_SIGN_IDENTITY:--}
PKG_SIGN_IDENTITY=${PKG_SIGN_IDENTITY:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
SDK_PATH=${SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}

rm -rf "$BUILD_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources/python" "$PKG_ROOT/Applications"
mkdir -p "$BUILD_DIR/module-cache"

xcrun swiftc \
  -swift-version 5 \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macosx13.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -O \
  -parse-as-library \
  -framework SwiftUI \
  -framework AppKit \
  -framework Security \
  "$APP_SOURCE_DIR/Sources/WhisperMacApp.swift" \
  -o "$CONTENTS_DIR/MacOS/WhisperMac"

cp "$APP_SOURCE_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$APP_SOURCE_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
ditto --norsrc --noextattr "$CLI_SOURCE_DIR/src/whisper_mac_cli" "$CONTENTS_DIR/Resources/python/whisper_mac_cli"
find "$CONTENTS_DIR/Resources/python" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$CONTENTS_DIR/Resources/python" -type f -name '*.pyc' -delete

if [ "$APP_SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP_DIR"
else
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$APP_SIGN_IDENTITY" \
    "$APP_DIR"
fi
ditto --norsrc --noextattr "$APP_DIR" "$PKG_ROOT/Applications/Whisper Mac.app"
xattr -cr "$PKG_ROOT"
find "$PKG_ROOT" -type f -name '._*' -delete

if [ -n "$PKG_SIGN_IDENTITY" ]; then
  COPYFILE_DISABLE=1 pkgbuild \
    --root "$PKG_ROOT" \
    --component-plist "$APP_SOURCE_DIR/Component.plist" \
    --identifier com.whispermac.pkg \
    --version "$VERSION" \
    --install-location / \
    --sign "$PKG_SIGN_IDENTITY" \
    --timestamp \
    "$PKG_PATH"
else
  COPYFILE_DISABLE=1 pkgbuild \
    --root "$PKG_ROOT" \
    --component-plist "$APP_SOURCE_DIR/Component.plist" \
    --identifier com.whispermac.pkg \
    --version "$VERSION" \
    --install-location / \
    "$PKG_PATH"
fi

if [ -n "$NOTARY_PROFILE" ]; then
  if [ -z "$PKG_SIGN_IDENTITY" ] || [ "$APP_SIGN_IDENTITY" = "-" ]; then
    echo "Для нотариализации задайте APP_SIGN_IDENTITY и PKG_SIGN_IDENTITY" >&2
    exit 1
  fi
  xcrun notarytool submit "$PKG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG_PATH"
  xcrun stapler validate "$PKG_PATH"
fi

echo "$PKG_PATH"
