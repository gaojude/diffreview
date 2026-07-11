#!/bin/bash
# Package a release: build MyIDE in release mode, assemble the branded DiffReview.app,
# and wrap it in a drag-to-install DMG at dist/DiffReview-v<version>.dmg.
set -euo pipefail

APP_NAME="DiffReview"
BUNDLE_ID="com.judegao.diffreview"
VERSION="0.1.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"

echo "=== Building release binary ==="
swift build -c release --product MyIDE
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "=== Creating $APP_NAME.app bundle ==="
DIST="$ROOT/dist"
# Assemble in a fresh temp dir and move into dist/ at the end: once a bundle has been
# launched, macOS can transiently refuse in-place writes to it ("Operation not permitted").
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_DIR/MyIDE" "$MACOS/$APP_NAME"
# HighlighterSwift's grammar/theme bundle (and any other SwiftPM resources).
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$RESOURCES/" \;

# The `diffreview` CLI: `diffreview .` opens the app on that directory, like `code .`.
# Named diffreview-cli because MacOS/ already holds the app binary `DiffReview` and the default
# APFS volume is case-insensitive — `diffreview` would silently overwrite it.
cp "$ROOT/scripts/diffreview-cli" "$MACOS/diffreview-cli"
chmod +x "$MACOS/diffreview-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle has a stable identity (helps window focus + TCC).
codesign --force --deep --sign - "$APP"

echo "=== Creating DMG ==="
STAGING="$WORK/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$WORK/$APP_NAME-v$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

rm -rf "$DIST"
mkdir -p "$DIST"
mv "$APP" "$DIST/"
mv "$DMG" "$DIST/"

echo "✓ Packaged $DIST/$(basename "$DMG")"
