#!/usr/bin/env node
// agent-harness.mjs — the MyIDE Agent Workspace sidecar.
//
// Speaks NDJSON over stdio with the app (see docs/agent-workspace.md):
//   harness -> app (stdout): hello, state, text, tool_use, turn_end, fatal
//   app -> harness (stdin):  user, tool_result, shutdown
//
// Two modes:
//   --mock <scenario.json> [--delay-ms N]   scripted demo — zero dependencies,
//                                           works offline with no API key
//   (no --mock)                             live Claude Agent SDK session
//
// The app is the tool server: every browser action goes out as a `tool_use`
// request and the harness blocks until the matching `tool_result` comes back.
// That single round-trip is what lets the app render the page live and record
// every step, in both modes, without the harness knowing anything about the
// browser engine.
//
// Requires Node >= 20. Mock mode must import nothing beyond node builtins so
// the demo runs on a machine that has never seen `npm install`.

import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
import process from 'node:process';

// ---------------------------------------------------------------------------
// Wire helpers
// ---------------------------------------------------------------------------

/// Write one protocol message: a single JSON object followed by a newline.
/// If stdout is gone the app is gone, so there is nobody left to serve.
function emit(message) {
  try {
    process.stdout.write(JSON.stringify(message) + '\n');
  } catch {
    process.exit(0);
  }
}

/// Diagnostics go to stderr only — stdout is reserved for the protocol.
function diag(text) {
  try {
    process.stderr.write(String(text) + '\n');
  } catch {
    // Nothing sensible to do if even stderr is closed.
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/// Exit without dropping protocol messages. Stdout to a pipe is asynchronous
/// in Node, so a bare process.exit can truncate whatever is still queued — an
/// empty write's callback fires only after everything before it has flushed.
function exitAfterFlush(code) {
  try {
    process.stdout.write('', () => process.exit(code));
    // Safety net in case stdout never drains (the app stopped reading).
    setTimeout(() => process.exit(code), 250).unref();
  } catch {
    process.exit(code);
  }
}

// A late EPIPE (app quit mid-write) surfaces as a stream error rather than a
// synchronous throw; treat it as a normal end of session.
process.stdout.on('error', () => process.exit(0));

// ---------------------------------------------------------------------------
// Tool round-trips
// ---------------------------------------------------------------------------

// Pending tool_use requests keyed by id; resolved when the app's tool_result
// arrives on stdin. Ids are "t1", "t2", ... across the whole session.
const pendingToolResults = new Map();
let toolCounter = 0;

/// Emit a tool_use and return a promise that settles with the app's
/// { ok, output } once the matching tool_result arrives.
function requestTool(command) {
  toolCounter += 1;
  const id = `t${toolCounter}`;
  const result = new Promise((resolve) => pendingToolResults.set(id, resolve));
  emit({ type: 'tool_use', id, command });
  return result;
}

// ---------------------------------------------------------------------------
// Stdin router (shared by both modes)
// ---------------------------------------------------------------------------

/// Read line-buffered NDJSON from stdin and dispatch. Malformed lines and
/// unknown message types are ignored for forward compatibility; stdin closing
/// or an explicit shutdown message ends the process cleanly.
function startStdinRouter(onUser) {
  const rl = createInterface({ input: process.stdin, terminal: false });
  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (trimmed === '') return;
    let message;
    try {
      message = JSON.parse(trimmed);
    } catch {
      diag(`ignoring malformed input line: ${trimmed}`);
      return;
    }
    if (!message || typeof message !== 'object') return;
    switch (message.type) {
      case 'user':
        if (typeof message.text === 'string') onUser(message.text);
        break;
      case 'tool_result': {
        const resolve = pendingToolResults.get(message.id);
        if (resolve) {
          pendingToolResults.delete(message.id);
          resolve({
            ok: message.ok !== false,
            output: typeof message.output === 'string' ? message.output : '',
          });
        } else {
          diag(`tool_result for unknown id: ${String(message.id)}`);
        }
        break;
      }
      case 'shutdown':
        exitAfterFlush(0);
        break;
      default:
        // Unknown message types are ignored (forward compatibility).
        break;
    }
  });
  rl.on('close', () => exitAfterFlush(0));
}

// ---------------------------------------------------------------------------
// Mock mode — scripted scenario, zero dependencies
// ---------------------------------------------------------------------------

// Exact demo-exhausted line from the spec; the app shows it verbatim.
const DEMO_EXHAUSTED_TEXT =
  "That's everything I know how to do in demo mode — but you can replay this any time from the Automations list.";

/// Play one scenario turn: emit each item in order (text straight through,
/// tools blocking on their result), pacing with delayMs between items so the
/// terminal reads like a live session rather than a dump.
async function playTurn(turn, delayMs) {
  emit({ type: 'state', value: 'working' });
  const items = turn && Array.isArray(turn.emit) ? turn.emit : null;
  if (!items) {
    // The script is over — every further user message gets the same gentle
    // pointer back to the Automations list.
    emit({ type: 'text', text: DEMO_EXHAUSTED_TEXT });
    emit({ type: 'state', value: 'idle' });
    emit({ type: 'turn_end' });
    return;
  }
  let first = true;
  for (const item of items) {
    if (!first) await sleep(delayMs);
    first = false;
    if (item && typeof item.text === 'string') {
      emit({ type: 'text', text: item.text });
    } else if (item && typeof item.tool === 'string') {
      // Block until the app has executed the command — this keeps the
      // transcript, the rendered page, and the recorder in lockstep.
      await requestTool(item.tool);
    } else {
      diag(`skipping unrecognized scenario item: ${JSON.stringify(item)}`);
    }
  }
  emit({ type: 'state', value: 'idle' });
  emit({ type: 'turn_end' });
}

function runMock(scenarioPath, delayMs) {
  let scenario;
  try {
    scenario = JSON.parse(readFileSync(scenarioPath, 'utf8'));
  } catch (err) {
    emit({
      type: 'fatal',
      message: `Could not load the demo scenario at ${scenarioPath}: ${err && err.message ? err.message : String(err)}`,
    });
    exitAfterFlush(1);
    return;
  }
  const turns = Array.isArray(scenario.turns) ? scenario.turns : [];
  emit({ type: 'hello', mode: 'mock', version: 1 });

  // User messages are consumed strictly in order; chaining on a promise keeps
  // turns serialized even if the app sends the next prompt early.
  let nextTurnIndex = 0;
  let chain = Promise.resolve();
  startStdinRouter(() => {
    const turnIndex = nextTurnIndex;
    nextTurnIndex += 1;
    chain = chain
      .then(() => playTurn(turns[turnIndex], delayMs))
      .catch((err) => diag(`mock turn failed: ${err && err.stack ? err.stack : String(err)}`));
  });
}

// ---------------------------------------------------------------------------
// Live mode — Claude Agent SDK
// ---------------------------------------------------------------------------

const TOOL_DESCRIPTION =
  'Execute one agent-browser command against the managed browser session. Commands: open <url>, snapshot, click <target>, fill <target> <text>, type <target> <text>, press <target> <Key>, get value <target>, get url, get title, wait, sleep <s>, screenshot. Target is @eN from the last snapshot or a "Quoted Label".';

// Teaches the agent the agent-browser workflow and the mock portal's
// real-world gotchas (custom radios, custom dropdowns, stale refs).
const SYSTEM_PROMPT = [
  'You are operating a web browser for a non-technical user through a single tool,',
  'agent_browser. Each call runs exactly one command and returns its output.',
  '',
  'Workflow rules:',
  '- Take a snapshot first to see the page. Element refs like @e3 come from the',
  '  most recent snapshot only.',
  '- Refs go stale: after any action that changes the page (open, click, press,',
  '  fill, type), take a fresh snapshot before using refs again.',
  '- Custom radio buttons often ignore clicks. If a click reports it did not',
  '  register, focus the radio and press Space on it instead.',
  '- Custom dropdowns (comboboxes) cannot be filled directly: open them with a',
  '  click or ArrowDown, move the highlight with ArrowDown/ArrowUp, and commit',
  '  with Enter.',
  '- Prefer quoted-label commands (for example: click "Sign in") over @refs when',
  '  repeating a known flow — labels survive page re-renders.',
  '- Narrate what you are doing in short, warm, plain English between tool calls',
  '  so someone watching the session can follow along.',
].join('\n');

// Real mode (--real): the tool executes the actual agent-browser CLI against
// headed Chrome on real websites, so the grammar is the real CLI's.
const REAL_TOOL_DESCRIPTION =
  'Execute one agent-browser CLI command against a REAL Chrome browser the user can see. ' +
  'Core commands: open <url> · snapshot -i (interactive elements with @eN refs; always -i) · ' +
  'click/dblclick/hover/focus @eN · fill @eN <text> (clears first) · type @eN <text> · ' +
  'press <Key> (acts on current focus, e.g. press Enter — focus @eN first) · ' +
  'check/uncheck @eN · select @eN <value> · scroll down 500 · scrollintoview @eN · ' +
  'find text "Sign In" click / find label "Email" fill <text> / find role button click --name "Submit" (semantic locators, no snapshot needed) · ' +
  'get text|value|attr|title|url · wait @eN | wait --text "..." | wait --url "**/path" | wait --load networkidle · screenshot <file.png>. ' +
  'One command per call; the output is returned.';

const REAL_SYSTEM_PROMPT = [
  'You are operating a REAL Chrome browser on real websites for a non-technical',
  'user, through a single tool: agent_browser. Each call runs one agent-browser',
  'CLI command and returns its output. The user watches the Chrome window.',
  '',
  'Workflow rules:',
  '- snapshot -i first to see the page; act on its @eN refs. Refs go stale after',
  '  anything changes the page — re-snapshot before reusing refs.',
  '- After any navigation or page-changing action, wait properly before the next',
  '  step: wait --load networkidle, wait --text "...", or wait --url "**/path".',
  '  Never assume the page is ready.',
  '- press acts on the current focus: focus @eN first, then press Enter (or use',
  '  fill, which commits text directly).',
  '- Prefer find text/label/role commands when repeating a known flow — they',
  '  survive re-renders and make recordings replayable.',
  '- NEVER enter usernames, passwords, or 2FA codes. If a page needs a sign-in,',
  '  tell the user to log in by hand in the Chrome window, then wait for them',
  '  (wait --url or wait --text on something only visible after login).',
  '- Be conservative on real sites: no purchases, no deletions, no posting, and',
  '  no form submissions with real-world consequences unless the user explicitly',
  '  asked for exactly that.',
  '- Narrate what you are doing in short, warm, plain English between tool calls',
  '  so someone watching can follow along.',
].join('\n');

async function runLive(realBrowser) {
  let sdk;
  let z;
  try {
    sdk = await import('@anthropic-ai/claude-agent-sdk');
    ({ z } = await import('zod'));
  } catch (err) {
    diag(`SDK import failed: ${err && err.message ? err.message : String(err)}`);
    emit({ type: 'fatal', message: 'Live mode needs the Claude Agent SDK — run: cd harness && npm install' });
    exitAfterFlush(1);
    return;
  }

  emit({ type: 'hello', mode: 'live', version: 1 });

  // Streaming-input mode: stdin `user` messages feed this queue, and the async
  // generator below hands them to query() one at a time. The generator never
  // returns — session end is always an explicit shutdown/stdin-close/stream-end.
  const queue = [];
  let wake = null;
  startStdinRouter((text) => {
    queue.push(text);
    if (wake) {
      const w = wake;
      wake = null;
      w();
    }
  });

  async function* userMessages() {
    while (true) {
      while (queue.length > 0) {
        const text = queue.shift();
        emit({ type: 'state', value: 'working' });
        yield { type: 'user', message: { role: 'user', content: [{ type: 'text', text }] } };
      }
      await new Promise((resolve) => {
        wake = resolve;
      });
    }
  }

  /// Translate one SDK stream message into protocol messages. SDK versions
  /// differ on exact shapes, so read defensively: the API message usually sits
  /// at `message.message`, but tolerate content at the top level too.
  function handleSdkMessage(message) {
    if (!message || typeof message !== 'object') return;
    if (message.type === 'assistant') {
      const content = message.message && Array.isArray(message.message.content)
        ? message.message.content
        : Array.isArray(message.content)
          ? message.content
          : [];
      for (const block of content) {
        if (block && block.type === 'text' && typeof block.text === 'string' && block.text.length > 0) {
          emit({ type: 'text', text: block.text });
        }
      }
    } else if (message.type === 'result') {
      emit({ type: 'state', value: 'idle' });
      emit({ type: 'turn_end' });
    }
    // system/init, stream events, tool progress, etc. are intentionally ignored.
  }

  try {
    const browser = sdk.createSdkMcpServer({
      name: 'browser',
      version: '1.0.0',
      tools: [
        sdk.tool(
          'agent_browser',
          realBrowser ? REAL_TOOL_DESCRIPTION : TOOL_DESCRIPTION,
          { command: z.string() },
          async (args) => {
            // Round-trip through the app, which executes the command on the
            // in-process engine and answers with tool_result.
            const command = args && typeof args.command === 'string' ? args.command : '';
            const result = await requestTool(command);
            return { content: [{ type: 'text', text: result.output }] };
          },
        ),
      ],
    });

    const stream = sdk.query({
      prompt: userMessages(),
      options: {
        mcpServers: { browser },
        allowedTools: ['mcp__browser__agent_browser'],
        permissionMode: 'bypassPermissions',
        maxTurns: 50,
        systemPrompt: realBrowser ? REAL_SYSTEM_PROMPT : SYSTEM_PROMPT,
      },
    });

    for await (const message of stream) {
      try {
        handleSdkMessage(message);
      } catch (err) {
        // One odd message must never take the whole session down.
        diag(`error handling SDK message: ${err && err.stack ? err.stack : String(err)}`);
      }
    }
  } catch (err) {
    diag(`live session error: ${err && err.stack ? err.stack : String(err)}`);
    emit({
      type: 'fatal',
      message: `The live agent session ended unexpectedly: ${err && err.message ? err.message : String(err)}`,
    });
    exitAfterFlush(1);
    return;
  }

  // The SDK closed its stream on its own (e.g. maxTurns reached) — report idle
  // so the app is not stuck in "working", then exit cleanly.
  emit({ type: 'state', value: 'idle' });
  exitAfterFlush(0);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  let mockRequested = false;
  let mockPath = null;
  let delayMs = 150;
  let realBrowser = false;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--mock') {
      mockRequested = true;
      mockPath = typeof argv[i + 1] === 'string' ? argv[i + 1] : null;
      i += 1;
    } else if (arg === '--delay-ms') {
      const parsed = Number(argv[i + 1]);
      if (Number.isFinite(parsed) && parsed >= 0) delayMs = parsed;
      i += 1;
    } else if (arg === '--real') {
      // The app executes commands against the real agent-browser CLI; teach
      // the model the real grammar and real-web ground rules.
      realBrowser = true;
    } else {
      diag(`ignoring unknown argument: ${arg}`);
    }
  }
  return { mockRequested, mockPath, delayMs, realBrowser };
}

function main() {
  const { mockRequested, mockPath, delayMs, realBrowser } = parseArgs(process.argv.slice(2));
  if (mockRequested) {
    if (!mockPath) {
      emit({ type: 'fatal', message: 'The --mock flag needs a scenario path, like: --mock scenarios/insurance-claim.json' });
      exitAfterFlush(1);
      return;
    }
    runMock(mockPath, delayMs);
  } else {
    runLive(realBrowser).catch((err) => {
      diag(`unexpected live-mode failure: ${err && err.stack ? err.stack : String(err)}`);
      emit({
        type: 'fatal',
        message: `The live agent session ended unexpectedly: ${err && err.message ? err.message : String(err)}`,
      });
      exitAfterFlush(1);
    });
  }
}

main();
