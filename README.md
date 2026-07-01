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
- **Voice codebase agent** — select code, click the microphone that appears beside the
  selection, ask a question aloud, and get a streamed AI response. The selection anchors a
  read-only local agent loop: the model must inspect the Git diff first, then can call local
  tools for full-codebase file listing, file reads, and text search as needed.
- **Native UX** — `NavigationSplitView` sidebar/detail, standard resize/collapse, dark mode,
  keyboard navigation, and window focus when launched from a terminal.
- **Liquid Glass** — the sidebar, toolbar, and window chrome adopt macOS 26's Liquid Glass
  automatically; the content pane adds a floating glass header bar, a glass "Reveal in Finder"
  button (`GlassEffectContainer` + `.glassEffect`/`.buttonStyle(.glass)`), and glass placeholder
  cards, with code scrolling translucently underneath the header.

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

## Voice questions

Voice questions use Apple Speech for local speech-to-text, a streaming Chat Completions agent
for the answer, hosted text-to-speech for the final spoken summary, and macOS speech synthesis
only as a fallback. Select a range in the code viewer, then click the inline microphone beside
the selection. Tool progress is shown in the panel instead of being spoken aloud.

```sh
export AI_GATEWAY_API_KEY=...          # preferred: routes through Vercel AI Gateway
export AI_GATEWAY_MODEL=openai/gpt-5.5 # optional; this is the Gateway default
export AI_GATEWAY_TTS_MODEL=openai/gpt-4o-mini-tts # optional
export MYIDE_TTS_VOICE=marin           # optional
export MYIDE_TTS_SPEED=1.04            # optional

# Direct OpenAI also works:
# export OPENAI_API_KEY=sk-...
# export OPENAI_MODEL=gpt-5.5
# export OPENAI_TTS_MODEL=gpt-4o-mini-tts

my-ide .
```

On first use, macOS asks for Microphone and Speech Recognition permission. The first request
sends only the spoken question, the selected lines, and the changed-file summary. After that, the
model can call read-only local tools: `get_git_diff`, `list_files`, `read_file`, and
`search_text`. `get_git_diff` is prioritized first for branch-review semantics, while
`list_files`, `read_file`, and `search_text` can inspect the rest of the opened codebase.
Generated/dependency directories such as `.git`, `.build`, `build`, and
`node_modules` are ignored. A real selection is required before voice ask starts.

## Testing

Full Xcode's UI-test stack (XCUITest, `swift test`) is optional; the primary checks run with
just the toolchain:

```sh
./scripts/selftest.sh    # pure-logic assertions (Git changes, sort, binary sniff, path resolution)
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
