#!/bin/bash
# End-to-end agent-loop test against a local OpenAI-compatible mock server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"

PORT="${MYIDE_MOCK_AI_PORT:-8765}"
python3 "$ROOT/scripts/mock-ai-server.py" --port "$PORT" >/tmp/myide-mock-ai.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" >/dev/null 2>&1 || true' EXIT

for _ in {1..50}; do
  if grep -q "mock ai server listening" /tmp/myide-mock-ai.log 2>/dev/null; then
    break
  fi
  sleep 0.1
done

"$ROOT/scripts/build.sh" >/dev/null
AI_GATEWAY_API_KEY=mock \
MYIDE_AI_BASE_URL="http://127.0.0.1:$PORT" \
MYIDE_AI_MODEL=mock-chat \
"$ROOT/build/MyIDE.app/Contents/MacOS/MyIDE" --selection-chat-agent-self-test
