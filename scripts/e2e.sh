#!/bin/bash
# End-to-end smoke: logic self-test → build app → launch on a fixture → assert UI via
# System Events → capture a screenshot artifact → quit.
#
# NOTE: the UI-assertion step needs a one-time Accessibility grant for your terminal
# (System Settings → Privacy & Security → Accessibility). Without it, System Events
# errors with -1719/-25211; the self-test + build steps still validate the core.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"

echo "▸ [1/3] Logic self-test"
if ! swift run -c release MyIDESelfTest; then
  echo "✗ self-test failed"; exit 1
fi

echo "▸ [2/3] Build app bundle"
"$ROOT/scripts/build.sh"
APP="$ROOT/build/MyIDE.app"

# Keep the accessibility assertion pointed at this run, not a stale local test process.
osascript -e 'quit app "MyIDE"' 2>/dev/null || true
sleep 0.5
pkill -x MyIDE 2>/dev/null || true

# Small fixture project.
FIX="$(mktemp -d)"
mkdir -p "$FIX/src"
printf 'export const hello = () => "hi";\n' > "$FIX/src/index.ts"
printf '# Fixture\n\nHello **world**.\n' > "$FIX/README.md"
printf '{ "name": "fixture", "version": "1.0.0" }\n' > "$FIX/package.json"

# Make the fixture look like a small PR/branch: one committed branch edit and one local draft.
if command -v git >/dev/null 2>&1; then
  if ! git -C "$FIX" init -b main >/dev/null 2>&1; then
    git -C "$FIX" init >/dev/null 2>&1
    git -C "$FIX" checkout -b main >/dev/null 2>&1
  fi
  git -C "$FIX" config user.email "e2e@example.com"
  git -C "$FIX" config user.name "MyIDE E2E"
  git -C "$FIX" config commit.gpgsign false
  git -C "$FIX" add .
  git -C "$FIX" commit -m "initial fixture" >/dev/null 2>&1
  git -C "$FIX" checkout -b feature/change-tree >/dev/null 2>&1
  printf '# Fixture\n\nHello **branch changes**.\n' > "$FIX/README.md"
  git -C "$FIX" add README.md
  git -C "$FIX" commit -m "update readme" >/dev/null 2>&1
  printf 'export const draft = true;\n' > "$FIX/src/draft.ts"
fi

echo "▸ [3/3] Launch on fixture: $FIX"
open -n "$APP" --args "$FIX"

APP_PID=""
for _ in {1..40}; do
  APP_PID="$(pgrep -f "$APP/Contents/MacOS/MyIDE $FIX" | head -n 1 || true)"
  if [ -n "$APP_PID" ]; then break; fi
  sleep 0.25
done

if [ -z "$APP_PID" ]; then
  echo "✗ Could not find launched MyIDE process"
  rm -rf "$FIX"
  exit 1
fi

sleep 3

ART="$ROOT/build/e2e-screenshot.png"
osascript "$ROOT/scripts/e2e.applescript" "$APP_PID"
RESULT=$?

echo "▸ Capturing screenshot → $ART"
screencapture -x "$ART" 2>/dev/null || echo "  (screenshot skipped)"

# Quit cleanly. The Apple event does not need assistive access.
kill "$APP_PID" 2>/dev/null || osascript -e 'quit app "MyIDE"' 2>/dev/null
rm -rf "$FIX"

if [ "$RESULT" -eq 0 ]; then
  echo "✓ E2E smoke passed"
else
  echo "✗ E2E UI step failed (exit $RESULT) — likely missing Accessibility permission."
  echo "  Grant your terminal Accessibility access, then re-run. Core logic + build already passed above."
fi
exit "$RESULT"
