#!/bin/bash
# Headless end-to-end check of the Assistant workspace: spawns the mock agent harness,
# replays the demo insurance-claim session against the in-process portal, records it,
# saves the automation, and replays it. No API key, no network. Skips (exit 0) when
# node is not installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"

"$ROOT/scripts/build.sh"

APP="$ROOT/build/MyIDE.app"
echo "▸ Running agent workspace self-test…"
"$APP/Contents/MacOS/MyIDE" --agent-workspace-self-test
echo "✓ agent workspace self-test passed"
