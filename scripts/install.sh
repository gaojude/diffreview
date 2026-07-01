#!/bin/bash
# Build the app, then install the `my-ide` launcher shim to /usr/local/bin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh"

# Destination bin dir: first arg, else $MYIDE_PREFIX, else /usr/local/bin.
DEST_DIR="${1:-${MYIDE_PREFIX:-/usr/local/bin}}"
APP_BUNDLE="$ROOT/build/MyIDE.app"
SHIM="$DEST_DIR/my-ide"

TMP="$(mktemp)"
# Runtime vars are escaped (\$) so they resolve when the shim runs, not now.
# `open -n` launches through LaunchServices, which brings the window to the front
# (a bare `binary &` launch stays in the background); --args passes the directory.
cat > "$TMP" <<EOF
#!/bin/sh
# Launcher for MyIDE — resolves the target directory and opens the app on it (foreground).
APP="$APP_BUNDLE"
TARGET="\${1:-.}"
DIR="\$(cd "\$TARGET" 2>/dev/null && pwd)" || { echo "my-ide: not a directory: \$TARGET" >&2; exit 1; }
open -n "\$APP" --args "\$DIR"
EOF
chmod +x "$TMP"

echo "▸ Installing launcher → $SHIM"
if [ -w "$DEST_DIR" ] || { [ ! -e "$DEST_DIR" ] && [ -w "$(dirname "$DEST_DIR")" ]; }; then
  mkdir -p "$DEST_DIR"
  mv "$TMP" "$SHIM"
else
  echo "  (need sudo to write $DEST_DIR — you may be prompted for your password)"
  sudo mkdir -p "$DEST_DIR"
  sudo mv "$TMP" "$SHIM"
  sudo chmod +x "$SHIM"
fi

echo "✓ Installed. Try:  cd /Users/judegao/Coding/next.js && my-ide ."
