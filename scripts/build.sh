#!/bin/bash
# Build MyIDE in release and assemble a native .app bundle at build/MyIDE.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"

echo "▸ Building MyIDE (release)…"
swift build -c release --product MyIDE

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/build/MyIDE.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_DIR/MyIDE" "$MACOS/MyIDE"
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$RESOURCES/" \;
cp "$ROOT/scripts/diffreview-cli" "$MACOS/diffreview-cli"
chmod +x "$MACOS/diffreview-cli"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MyIDE</string>
  <key>CFBundleDisplayName</key><string>MyIDE</string>
  <key>CFBundleExecutable</key><string>MyIDE</string>
  <key>CFBundleIdentifier</key><string>com.judegao.myide</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Folders open as attached projects (tabs). LSHandlerRank None: the diffreview shim and
       Dock drops can send folders here, but the app never becomes Finder's folder handler. -->
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

# Ad-hoc sign so the bundle has a stable identity (helps window focus + TCC). Non-fatal.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"

echo "✓ Built $APP"

echo "▸ Building Margin (release)…"
swift build -c release --product Margin

MARGIN_APP="$ROOT/build/Margin.app"
MARGIN_MACOS="$MARGIN_APP/Contents/MacOS"
MARGIN_RESOURCES="$MARGIN_APP/Contents/Resources"

echo "▸ Assembling $MARGIN_APP"
rm -rf "$MARGIN_APP"
mkdir -p "$MARGIN_MACOS" "$MARGIN_RESOURCES"
cp "$BIN_DIR/Margin" "$MARGIN_MACOS/Margin"
cp "$ROOT/scripts/margin-cli" "$MARGIN_MACOS/margin-cli"
chmod +x "$MARGIN_MACOS/margin-cli"

cat > "$MARGIN_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Margin</string>
  <key>CFBundleDisplayName</key><string>Margin</string>
  <key>CFBundleExecutable</key><string>Margin</string>
  <key>CFBundleIdentifier</key><string>com.judegao.margin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Text files open as reviewed replies. LSHandlerRank None: the margin shim and Dock
       drops can send files here, but the app never becomes Finder's text handler. -->
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

codesign --force --sign - "$MARGIN_APP" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"

echo "✓ Built $MARGIN_APP"
