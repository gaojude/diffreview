# MyIDE Agent Harness

The Node sidecar behind MyIDE's **Agent Workspace** ("Assistant") window. The app spawns
`agent-harness.mjs` and talks to it over NDJSON stdio: the harness runs the agent
conversation, and every browser action comes back to the app as a `tool_use` request that
the app executes on its in-process mock browser engine — so the UI renders the page live
and the recorder captures every step.

## Modes

- **Mock (demo) mode** — `node agent-harness.mjs --mock scenarios/insurance-claim.json
  [--delay-ms 150]`. Plays a scripted scenario, one turn per user message. Zero
  dependencies, no API key, works offline. Extra user messages after the script get a
  friendly "that's everything I know in demo mode" reply.
- **Live mode** — `node agent-harness.mjs` (no `--mock`). Runs a real Claude agent via the
  Claude Agent SDK, exposing one MCP tool (`agent_browser`) whose calls round-trip through
  the app. Requires the SDK to be installed and an Anthropic API key in the environment.

## Installing the SDK (live mode only)

```sh
cd harness
npm install
```

Mock mode never needs `npm install`. If live mode starts without the SDK present, the
harness reports: `Live mode needs the Claude Agent SDK — run: cd harness && npm install`.

## Wire protocol

One JSON object per line. Unknown message types are ignored on both sides; stderr is
diagnostics only.

| Direction | Message | Meaning |
|---|---|---|
| harness → app | `{"type":"hello","mode":"mock"\|"live","version":1}` | Startup handshake |
| harness → app | `{"type":"state","value":"idle"\|"working"}` | Plain-English-status driver |
| harness → app | `{"type":"text","text":"..."}` | Assistant prose for the transcript |
| harness → app | `{"type":"tool_use","id":"t1","command":"click @e3"}` | Run one agent-browser command; harness blocks until the result |
| harness → app | `{"type":"turn_end"}` | The assistant finished responding |
| harness → app | `{"type":"fatal","message":"..."}` | Unrecoverable error, human-readable |
| app → harness | `{"type":"user","text":"..."}` | A prompt typed by the user |
| app → harness | `{"type":"tool_result","id":"t1","ok":true,"output":"..."}` | Answer to the matching `tool_use` |
| app → harness | `{"type":"shutdown"}` | Exit cleanly (closing stdin does the same) |

## Scenario format

`scenarios/*.json`: `{"name": "...", "turns": [{"emit": [{"text": "..."} | {"tool": "<command>"}, ...]}]}`.
Each user message plays the next turn; text items stream as assistant prose, tool items
execute as agent-browser commands (in quoted-label form so replays survive ref
renumbering).
