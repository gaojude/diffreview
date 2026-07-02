#!/bin/bash
# Live E2E agent-loop test against Claude through Vercel AI Gateway.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/_env.sh"

if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
  echo "ANTHROPIC_AUTH_TOKEN is required for the live Claude test." >&2
  exit 2
fi

if [[ -z "${ANTHROPIC_BASE_URL:-}" ]]; then
  export ANTHROPIC_BASE_URL="https://ai-gateway.vercel.sh"
fi

if [[ -z "${ANTHROPIC_MODEL:-}" ]]; then
  export ANTHROPIC_MODEL="anthropic/claude-opus-4.8"
fi

if [[ "$ANTHROPIC_MODEL" == *"["* ]]; then
  echo "ANTHROPIC_MODEL '$ANTHROPIC_MODEL' was rejected by the OpenAI-compatible gateway route; using anthropic/claude-opus-4.8 for this live test." >&2
  export ANTHROPIC_MODEL="anthropic/claude-opus-4.8"
fi

"$ROOT/scripts/build.sh" >/dev/null

env -u AI_GATEWAY_API_KEY \
    -u OPENAI_API_KEY \
    "$ROOT/build/MyIDE.app/Contents/MacOS/MyIDE" --selection-chat-agent-live-test
