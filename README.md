# my-ide

A fast, **native macOS** branch-change browser. Run `my-ide .` in a Git project and get a
left-sidebar tree of the current branch/worktree changes and a right-side content viewer.

Built with SwiftUI + AppKit (no Electron/web) and packaged as a real `.app`, launched by a
thin `my-ide` command — like `code .`, but native.

## Features

- **Left sidebar branch change tree** — shows only files changed by the current branch and
  working tree, while preserving their folder structure like a filtered GitHub Desktop tree.
  The sidebar header shows the branch, base ref, and changed-file count.
- **Right diff pane** — selecting a changed file shows its Git patch against the PR merge-base
  plus local working-tree edits. Additions, deletions, hunks, and metadata are styled in a
  native `NSTextView`; oversized diffs show a placeholder instead of hanging.
- **Selection chat agent** — select code, type in the persistent agent chat pane, and get a
  streamed Markdown AI response. File references like `path/to/file.ts:12-18` are clickable and
  replace the main code pane with that source file/range. The selection anchors a read-only local
  agent loop: the model must inspect the Git diff first, then can call local tools for
  full-codebase file listing, file reads, and text search as needed.
- **Prompt fix accumulator** — capture read-only chat conclusions as fix prompts. The Fixes tab
  keeps a selectable list of handoff prompts with code location, selected context, requested
  change, and recent chat summary, then copies the selected prompts to the clipboard.
- **Native UX** — `NavigationSplitView` sidebar/detail, standard resize/collapse, dark mode,
  keyboard navigation, and window focus when launched from a terminal.
- **Liquid Glass** — the sidebar, toolbar, and window chrome adopt macOS 26's Liquid Glass
  automatically; the content pane adds a floating glass header bar, a glass "Reveal in Finder"
  button (`GlassEffectContainer` + `.glassEffect`/`.buttonStyle(.glass)`), and glass placeholder
  cards, with code scrolling translucently underneath the header.
- **Assistant workspace** (⇧⌘A, or launch with `--assistant`) — a terminal pane showing a
  Claude session beside a live browser pane the agent operates on, plus one-click
  **automations**: every browser action the agent takes is recorded and can be saved as a
  replayable script with a generated `SKILL.md` playbook. With the Claude Agent SDK
  installed (`cd harness && npm install`) **and** the real `agent-browser` CLI on the
  machine, live sessions drive an actual headed Chrome on real websites (the right pane
  becomes a live action feed, and recordings canonicalize to replay-stable `find` locators).
  Without them, the workspace falls back to a deterministic demo: a mock browser that
  mimics the `agent-browser` CLI's API design (`@eN` refs, snapshots, stale-ref semantics)
  against a fake insurance portal — fully offline, no API key. Design notes:
  `docs/agent-workspace.md`; end-to-end check: `./scripts/agent-workspace-test.sh`.

## Requirements

- macOS 26+ (Apple Silicon or Intel) — Liquid Glass APIs require the macOS 26 SDK
- Full **Xcode** (the SwiftUI macro plugins, e.g. `libSwiftUIMacros`, ship with Xcode, not the
  Command Line Tools), with the license accepted — run this once in a real Terminal:
  `sudo xcodebuild -license accept`

## Build & install

```sh
./scripts/build.sh      # → build/MyIDE.app
./scripts/install.sh     # → /usr/local/bin/my-ide  (may prompt for your password)
```

Then, from inside a Git project:

```sh
cd /path/to/your/project
my-ide .                 # opens changes rooted at the current directory
my-ide /some/other/dir   # or an explicit path inside a repository
```

`my-ide` with no argument opens the current directory; a non-existent path prints an error.

## Selection chat

Selection chat uses a streaming Chat Completions agent. The app has three work areas: the
sidebar tree, the code pane, and the agent chat pane. Select a range in the code viewer, type a
question in the chat pane, and watch the Markdown answer stream after a compact progress state.
Chat text follows the same font size as the code viewer.

Click repo-relative references such as `packages/app/page.tsx:24-31` in chat or tool output to
load that file in the code pane and highlight the cited lines. You can then select code in that
newly loaded file and continue asking questions from the same chat pane.

When a chat turn becomes an implementation request, the app stays read-only and captures a
paste-ready prompt instead. Use the Chat/Fixes tabs in the right pane to review accumulated fixes,
select one or more prompts, and copy them to a coding agent.

```sh
export AI_GATEWAY_API_KEY=...          # preferred: routes through Vercel AI Gateway
export AI_GATEWAY_MODEL=openai/gpt-5.5 # optional; this is the Gateway default

# Anthropic/Claude through Vercel AI Gateway also works:
# export ANTHROPIC_BASE_URL=https://ai-gateway.vercel.sh
# export ANTHROPIC_AUTH_TOKEN=...
# export ANTHROPIC_MODEL=anthropic/claude-opus-4.8
# Note: the OpenAI-compatible Gateway route rejected `anthropic/claude-opus-4-8[1m]`
# in live testing; use `anthropic/claude-opus-4.8` here.

# Direct OpenAI also works:
# export OPENAI_API_KEY=sk-...
# export OPENAI_MODEL=gpt-5.5

my-ide .
```

The first request sends only the typed question, the selected lines, and the changed-file
summary. After that, the model can call read-only local tools: `get_git_diff`, `list_files`,
`read_file`, and `search_text`. `get_git_diff` is prioritized first for branch-review
semantics, while `list_files`, `read_file`, and `search_text` can inspect the rest of the opened
codebase. Generated/dependency directories such as `.git`, `.build`, `build`, and
`node_modules` are ignored. A real selection is required before the chat bubble appears.

## Testing

Full Xcode's UI-test stack (XCUITest, `swift test`) is optional; the primary checks run with
just the toolchain:

```sh
./scripts/selftest.sh    # pure-logic assertions (Git changes, sort, binary sniff, path resolution)
./scripts/selection-chat-ui-test.sh # native pane layout harness for selection chat
./scripts/selection-chat-agent-test.sh # mock AI server for streaming, tools, fixes, persistence
./scripts/selection-chat-claude-live-test.sh # live Claude/Vercel AI Gateway agent loop
./scripts/e2e.sh         # self-test → build → launch on a fixture → assert window via a11y → screenshot
```

`e2e.sh`'s UI-assertion step drives the running app through the Accessibility API (macOS's
Playwright analog). It needs a one-time **Accessibility** grant for your terminal
(System Settings → Privacy & Security → Accessibility). Without it, System Events errors with
-1719/-25211; the self-test and build steps still pass and validate the core.

Views carry `accessibilityIdentifier`s (`sidebar`, `content-view`, `empty-state`, per-row
paths) — the macOS equivalent of Playwright test IDs — so a full XCUITest suite can be added
later without touching the app code.

## Architecture

```
Sources/
  MyIDECore/        Foundation-only logic (Git changes, listing, sort, binary sniff, root resolution)
  MyIDE/            SwiftUI app
    MyIDEApp        @main App + AppDelegate (activation policy, focus, quit-on-close)
    AppState        opened root + branch change tree + selected file
    FileNode        lazy filesystem node or static branch-change tree node
    RootView        NavigationSplitView(sidebar, detail)
    FileTreeView    branch/base header + recursive changed-file DisclosureGroup rows
    ContentPaneView async file load with directory/size/binary guards
    CodeTextView    NSViewRepresentable read-only NSTextView
  MyIDESelfTest/    logic assertion harness (exits non-zero on failure)
scripts/            build / install / selftest / e2e
```

### Why it stays fast

- The Git change tree is built from changed paths, so unchanged directories are never rendered.
- Filesystem fallback nodes still read one directory level at a time, on expand, and cache
  children.
- `List` virtualizes rows (only visible ones render).
- File contents load off the main thread; the load auto-cancels when you pick another file.
- Large text renders in `NSTextView`, which handles big documents far better than SwiftUI `Text`.
