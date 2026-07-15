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

# Margin gets its own shim: review a reply file (`margin notes.md`) or pipe one in
# (`some-command | margin -`, or bare `margin` on the receiving end of a pipe).
MARGIN_APP_BUNDLE="$ROOT/build/Margin.app"
MARGIN_SHIM="$DEST_DIR/margin"
MARGIN_TMP="$(mktemp)"
cat > "$MARGIN_TMP" <<EOF
#!/bin/sh
# Launcher for Margin (source build) — opens a reply file for review; \`-\` reads stdin.
APP="$MARGIN_APP_BUNDLE"
TARGET="\${1:--}"
if [ "\$TARGET" = "-" ]; then
  if [ -t 0 ]; then
    echo "usage: margin <reply.md>   (or: some-command | margin -)" >&2
    exit 2
  fi
  INBOX="\$HOME/Library/Application Support/Margin/Inbox"
  mkdir -p "\$INBOX"
  FILE="\$INBOX/reply-\$(date +%Y%m%d-%H%M%S).md"
  cat > "\$FILE"
else
  DIR="\$(cd "\$(dirname "\$TARGET")" 2>/dev/null && pwd)" || { echo "margin: not a file: \$TARGET" >&2; exit 1; }
  FILE="\$DIR/\$(basename "\$TARGET")"
  [ -f "\$FILE" ] || { echo "margin: not a file: \$TARGET" >&2; exit 1; }
fi
open -n "\$APP" --args "\$FILE"
EOF
chmod +x "$MARGIN_TMP"

echo "▸ Installing launchers → $SHIM, $MARGIN_SHIM"
if [ -w "$DEST_DIR" ] || { [ ! -e "$DEST_DIR" ] && [ -w "$(dirname "$DEST_DIR")" ]; }; then
  mkdir -p "$DEST_DIR"
  mv "$TMP" "$SHIM"
  mv "$MARGIN_TMP" "$MARGIN_SHIM"
  ln -sf "$SHIM" "$DEST_DIR/my-ide"
else
  echo "  (need sudo to write $DEST_DIR — you may be prompted for your password)"
  sudo mkdir -p "$DEST_DIR"
  sudo mv "$TMP" "$SHIM"
  sudo chmod +x "$SHIM"
  sudo mv "$MARGIN_TMP" "$MARGIN_SHIM"
  sudo chmod +x "$MARGIN_SHIM"
  sudo ln -sf "$SHIM" "$DEST_DIR/my-ide"
fi

echo "✓ Installed. Try:  cd /path/to/your/project && diffreview ."
echo "            and:  margin /path/to/reply.md   (or: pbpaste | margin -)"
