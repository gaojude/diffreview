#!/bin/bash
# Deterministic UI harness for the selection-anchored chat overlay.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"

"$ROOT/scripts/build.sh" >/dev/null
"$ROOT/build/MyIDE.app/Contents/MacOS/MyIDE" --selection-chat-overlay-self-test
