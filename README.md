# DiffReview

Native macOS code review for the agent era. Run `diffreview .` in a Git project and the window
**is** the diff: every change on your branch as one scrolling document. Read it like a pull
request — check files off as reviewed, comment on lines — then copy the whole review as a
single prompt-ready block for your coding agent.

Built with SwiftUI + AppKit (no Electron, no web view), packaged as a real `.app`, launched
by a thin `diffreview` command — like `code .`, but native.

## Features

- **The diff is the window** — every file changed by the branch and working tree, one
  scrolling document against the merge base. Unified or split (old | new) layout with locked
  scrolling and a draggable divider; a line-number gutter shows real file line numbers with
  `+`/`−` markers.
- **Review like GitHub** — sticky per-file header bars with change stats, a collapse
  chevron, and a `[ ] Reviewed` checkbox that folds the file away. Collapse state and your
  reading position persist per repo + branch, so a review survives relaunches.
- **Comments become a prompt** — select lines and press `⌘K`: a glass composer opens inline
  under the selection. Comments collect in a side panel, jump back to their code on click,
  and **Copy** exports the entire review as one block ready to paste into Claude Code or any
  coding agent.
- **Hunk-by-hunk navigation** — `⌥⌘↓` / `⌥⌘↑` step through changes at GitHub's granularity
  (one stop per hunk), with a "Change 3 of 41" toast.
- **Per-commit scope** — a toolbar picker re-scopes the document to a single commit's diff,
  or back to all branch changes.
- **The branch's PR, one click away** — when the GitHub CLI (`gh`) resolves a pull request
  for the reviewed branch, a `#123` toolbar button opens it in your browser (and flags
  `Draft` / `Merged` / `Closed` states). No `gh`, no PR: no button.
- **Many PRs, one window** — `diffreview` a second project (or drop its folder on the Dock
  icon) and it attaches to the running window as a tab instead of opening another window.
  Tabs are labeled with the folder name and PR number; each keeps its own scope, comments,
  and reading position. `⌘⇧]` / `⌘⇧[` switch projects.
- **⌘-click definitions & references** — TypeScript-aware (tsserver-backed): ⌘-click a
  usage to open its definition in a floating Explorer panel that never disturbs the diff;
  ⌘-click a declaration to drop down everywhere it's used.
- **Find** — `⌘F` in the diff and in the Explorer panel.
- **Real syntax highlighting on diffs** — rows are colored from the *complete* file's
  highlighting, matched by line number, so truncated hunks never mislead the lexer.
- **Liquid Glass** — toolbar, header bars, composer, and overlays adopt macOS 26's glass
  treatment; code scrolls translucently underneath.

## Requirements

- macOS 26+ (Liquid Glass APIs require the macOS 26 SDK)
- For ⌘-click definitions: Node.js plus a `typescript` install reachable from the reviewed
  project (its own `node_modules` works)
- For the PR toolbar button: the GitHub CLI (`gh`), logged in (`gh auth login`)
- To build from source: full **Xcode** (the SwiftUI macro plugins ship with Xcode, not the
  Command Line Tools), with the license accepted: `sudo xcodebuild -license accept`

## Install

Download the DMG from [diffreview.dev](https://diffreview.dev), drag **DiffReview** to Applications,
and open it. Choose **Open Project Folder…** on the welcome screen (or press `⌘O`). To use
DiffReview from Terminal, click **Install CLI** on that same screen.

You can also link the bundled CLI manually:

```sh
sudo xattr -cr /Applications/DiffReview.app
sudo ln -sf /Applications/DiffReview.app/Contents/MacOS/diffreview-cli /usr/local/bin/diffreview
```

Or build from source:

```sh
./scripts/install.sh    # builds the app and installs the `diffreview` shim
```

Then, from inside any Git repository:

```sh
diffreview .               # review the current branch's changes
diffreview /some/repo      # or an explicit path
diffreview wt-a wt-b       # several projects at once, one window, one tab each
diffreview ../other-repo   # while a review is open: attaches as another tab
```

## Margin — review a reply like a diff

The repo also builds **Margin**, a sibling app for reviewing an *agent's prose reply* the
way DiffReview reviews a branch. Pipe a reply in and the window is the reply:

```sh
margin notes.md          # review a file
pbpaste | margin -       # or pipe a reply straight in
```

- **Character-granular comments** — select any passage, down to a single word (not just
  whole lines), and press `⌘K`: the same glass composer opens under the selection.
- **The same review loop** — comments collect in the side pane with exact-range teal
  highlights; **Copy** exports one prompt-ready block that quotes each selected passage
  verbatim, ready to paste back into the agent.
- **Agent-collectable reviews** — every review persists per content hash under
  `~/Library/Application Support/Margin/Reviews`, and `last-review.json` points at the
  newest one, so an agent can read the comments programmatically instead of via the
  clipboard.

`scripts/install.sh` installs the `margin` shim alongside `diffreview`.

## Shortcuts

| Key           | Action                                             |
| ------------- | -------------------------------------------------- |
| `⌘K`          | Comment on the selected lines                      |
| `⌘F`          | Find (diff view or Explorer panel)                 |
| `⌥⌘↓` / `⌥⌘↑` | Jump to next / previous change                     |
| `⌘⇧]` / `⌘⇧[` | Show next / previous attached project              |
| `⌘-click`     | Go to definition (on a declaration: references)    |
| `⌘=` / `⌘−` / `⌘0` | Adjust / reset font size                      |
| `⏎` / `⌘⏎` / `esc` | In the composer: newline / save / cancel      |

## Testing

The primary checks run with just the Swift toolchain — no XCTest:

```sh
./scripts/selftest.sh   # 150+ pure-logic assertions (diff model, comments, tsserver protocol)
./scripts/e2e.sh        # self-test → build → launch on a fixture → assert window via a11y
```

`e2e.sh`'s UI-assertion step drives the app through the Accessibility API and needs a
one-time Accessibility grant for your terminal (System Settings → Privacy & Security →
Accessibility). Without it, the self-test and build steps still pass.

Live tsserver tests are gated behind `MYIDE_TS_FIXTURE=/path/to/ts-project`.

## Architecture

```
Sources/
  MyIDECore/      Foundation-only logic: git change sets, side-by-side diff document,
                  review comments + prompt formatter, tsserver client, persistence
  MyIDE/          SwiftUI/AppKit app: diff panes (NSTextView), sticky header bars,
                  inline composer, comments pane, floating Explorer panel
  MyIDESelfTest/  assertion harness (runs under plain swift build, exits non-zero on failure)
scripts/          build / install / selftest / e2e
package.sh        release packaging → dist/DiffReview-v<version>.dmg
web/              diffreview.dev landing page (Next.js, deployed on Vercel)
```

Internal target names keep the project's working title (`MyIDE`); the product is DiffReview.

### Why it stays fast

- Restyles apply syntax colors as **attribute-only** passes over the existing text storage —
  the document never relayouts, so scroll position can't pop.
- Overlay chrome (header bars, gutter, comment markers) is positioned by fixed-row-height
  arithmetic on every scroll tick — no layout queries in the scroll path.
- Highlighting runs off the main thread on whole files, mapped back per row by line number;
  stale passes bail before doing work.
- `NSTextView` (TextKit) renders the document; it handles multi-thousand-row diffs far
  better than SwiftUI text.

## License

MIT — see [LICENSE](LICENSE).
