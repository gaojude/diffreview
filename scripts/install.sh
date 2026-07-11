#!/bin/bash
# Build the app from source, then install the `diffreview` launcher shim to /usr/local/bin
# (plus a `my-ide` alias for anyone used to the working title).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh"

# Destination bin dir: first arg, else $DIFFREVIEW_PREFIX, else /usr/local/bin.
DEST_DIR="${1:-${DIFFREVIEW_PREFIX:-/usr/local/bin}}"
APP_BUNDLE="$ROOT/build/MyIDE.app"
SHIM="$DEST_DIR/diffreview"

TMP="$(mktemp)"
# Runtime vars are escaped (\$) so they resolve when the shim runs, not now.
# `open -n` launches through LaunchServices, which brings the window to the front
# (a bare `binary &` launch stays in the background); --args passes the directory.
cat > "$TMP" <<EOF
#!/bin/sh
# Launcher for DiffReview (source build) — resolves the target directory and opens the app
# on it (foreground). Reviewing a single commit is done in-app via the commit picker.
APP="$APP_BUNDLE"
TARGET="\${1:-.}"
DIR="\$(cd "\$TARGET" 2>/dev/null && pwd)" || { echo "diffreview: not a directory: \$TARGET" >&2; exit 1; }
open -n "\$APP" --args "\$DIR"
EOF
chmod +x "$TMP"

echo "▸ Installing launcher → $SHIM"
if [ -w "$DEST_DIR" ] || { [ ! -e "$DEST_DIR" ] && [ -w "$(dirname "$DEST_DIR")" ]; }; then
  mkdir -p "$DEST_DIR"
  mv "$TMP" "$SHIM"
  ln -sf "$SHIM" "$DEST_DIR/my-ide"
else
  echo "  (need sudo to write $DEST_DIR — you may be prompted for your password)"
  sudo mkdir -p "$DEST_DIR"
  sudo mv "$TMP" "$SHIM"
  sudo chmod +x "$SHIM"
  sudo ln -sf "$SHIM" "$DEST_DIR/my-ide"
fi

echo "✓ Installed. Try:  cd /path/to/your/project && diffreview ."
