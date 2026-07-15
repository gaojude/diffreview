#!/bin/bash
# Package a release: build MyIDE and Margin in release mode, assemble the branded
# DiffReview.app and Margin.app, and wrap both in a drag-to-install DMG at
# dist/DiffReview-v<version>.dmg.
set -euo pipefail

APP_NAME="DiffReview"
BUNDLE_ID="com.judegao.diffreview"
VERSION="0.4.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"

echo "=== Building release binaries ==="
swift build -c release --product MyIDE
swift build -c release --product Margin
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
  <!-- Folders open as attached projects (tabs). LSHandlerRank None: the diffreview shim and
       Dock drops can send folders here, but DiffReview never becomes Finder's folder handler. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Project Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle has a stable identity (helps window focus + TCC).
codesign --force --deep --sign - "$APP"

echo "=== Creating Margin.app bundle ==="
MARGIN_APP="$WORK/Margin.app"
MARGIN_MACOS="$MARGIN_APP/Contents/MacOS"
MARGIN_RESOURCES="$MARGIN_APP/Contents/Resources"
mkdir -p "$MARGIN_MACOS" "$MARGIN_RESOURCES"

cp "$BIN_DIR/Margin" "$MARGIN_MACOS/Margin"
# The `margin` CLI: `margin reply.md` (or a pipe) opens the reply for review. Lowercase
# margin-cli is safe here — MacOS/ holds `Margin` and APFS is case-insensitive, so the
# distinct name avoids a silent overwrite, same as diffreview-cli.
cp "$ROOT/scripts/margin-cli" "$MARGIN_MACOS/margin-cli"
chmod +x "$MARGIN_MACOS/margin-cli"

cat > "$MARGIN_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Margin</string>
  <key>CFBundleDisplayName</key><string>Margin</string>
  <key>CFBundleExecutable</key><string>Margin</string>
  <key>CFBundleIdentifier</key><string>com.judegao.margin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Text files open as reviewed replies. LSHandlerRank None: the margin shim and Dock
       drops can send files here, but Margin never becomes Finder's text handler. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Reply</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$MARGIN_APP"

echo "=== Creating DMG ==="
STAGING="$WORK/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
cp -R "$MARGIN_APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$WORK/$APP_NAME-v$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

rm -rf "$DIST"
mkdir -p "$DIST"
mv "$APP" "$DIST/"
mv "$MARGIN_APP" "$DIST/"
mv "$DMG" "$DIST/"

echo "✓ Packaged $DIST/$(basename "$DMG")"
