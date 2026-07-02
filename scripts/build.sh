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

# The agent harness (node sidecar + demo scenario) ships inside the bundle so the
# Assistant window works from a Finder launch, not just from a repo checkout.
cp -R "$ROOT/harness" "$RESOURCES/harness"
rm -rf "$RESOURCES/harness/node_modules"

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
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle has a stable identity (helps window focus + TCC). Non-fatal.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"

echo "✓ Built $APP"
