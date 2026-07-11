import Foundation
import MyIDECore

// Lightweight assertion harness. Runs under Command Line Tools (no XCTest / xctest tool).
// Exits non-zero if any check fails so scripts/CI can gate on it.

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

func section(_ name: String) { print("• \(name)") }

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

func runGit(_ arguments: [String], in directory: URL) -> CommandResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory.path] + arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    return CommandResult(
        status: process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

@discardableResult
func checkGit(_ arguments: [String], in directory: URL, _ label: String) -> Bool {
    guard let result = runGit(arguments, in: directory), result.status == 0 else {
        failures += 1
        print("  FAIL \(label)")
        return false
    }
    print("  ok   \(label)")
    return true
}

// MARK: - sortEntries: directories first, then case-insensitive by name

section("sortEntries")
do {
    func e(_ name: String, _ dir: Bool) -> DirectoryEntry {
        DirectoryEntry(url: URL(fileURLWithPath: "/x/\(name)"), name: name, isDirectory: dir)
    }
    let sorted = FileSystem.sortEntries([e("z.txt", false), e("App", true), e("a.txt", false), e("Zebra", true)])
    check(sorted.map(\.name) == ["App", "Zebra", "a.txt", "z.txt"], "dirs first, case-insensitive lexical")
}

// MARK: - isProbablyBinary

section("isProbablyBinary")
do {
    check(FileSystem.isProbablyBinary(Data([0x68, 0x69, 0x00, 0x21])) == true, "NUL byte -> binary")
    check(FileSystem.isProbablyBinary("hello world\nline 2".data(using: .utf8)!) == false, "ascii text -> not binary")
    check(FileSystem.isProbablyBinary("héllo — 世界 🚀".data(using: .utf8)!) == false, "utf-8 text -> not binary")
    check(FileSystem.isProbablyBinary(Data([0xFF, 0xFE, 0xFD])) == true, "small invalid utf-8 -> binary")
    check(FileSystem.isProbablyBinary(Data()) == false, "empty -> not binary")
    var headTextThenNUL = Data(repeating: 0x41, count: 9000) // 9 KB of 'A' — past the 8 KB sample
    headTextThenNUL.append(Data(repeating: 0x00, count: 512))
    check(FileSystem.isProbablyBinary(headTextThenNUL) == true, "NUL past 8 KB head still -> binary")
}

// MARK: - decodeText

section("decodeText")
do {
    check(FileSystem.decodeText("plain".data(using: .utf8)!) == "plain", "utf-8 round-trips")
    check(FileSystem.decodeText(Data([0xFF, 0xFE])).isEmpty == false, "invalid bytes decode lossily (non-empty)")
}

// MARK: - maxFileSize sanity

section("maxFileSize")
check(FileSystem.maxFileSize == 5 * 1024 * 1024, "cap is 5 MB")

// MARK: - FontSizes.clamp

section("FontSizes.clamp")
check(FontSizes.clamp(FontSizes.maximum + 10) == FontSizes.maximum, "clamps above max to max")
check(FontSizes.clamp(FontSizes.minimum - 10) == FontSizes.minimum, "clamps below min to min")
check(FontSizes.clamp(FontSizes.default) == FontSizes.default, "in-range value unchanged")

// MARK: - AppConfiguration persistence

section("AppConfiguration persistence")
do {
    let suiteName = "myide-selftest-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = AppConfigurationStore(defaults: defaults, key: "configuration", defaultValue: .default)
    check(store.load() == .default, "missing configuration returns default")

    store.save(AppConfiguration(fontSize: 22))
    check(store.load().fontSize == 22, "saved font size round-trips")

    store.save(AppConfiguration(fontSize: FontSizes.maximum + 10))
    check(store.load().fontSize == FontSizes.maximum, "configuration clamps persisted font size")

    defaults.set(Data("not-json".utf8), forKey: "configuration")
    check(store.load() == .default, "invalid persisted configuration falls back to default")
}

// MARK: - SyntaxLanguageResolver

section("SyntaxLanguageResolver")
do {
    check(SyntaxLanguageResolver.languageName(for: URL(fileURLWithPath: "/x/App.swift")) == "swift",
          "maps Swift extension")
    check(SyntaxLanguageResolver.languageName(for: URL(fileURLWithPath: "/x/Package.swift")) == "swift",
          "maps exact package manifest name")
    check(SyntaxLanguageResolver.languageName(for: URL(fileURLWithPath: "/x/Dockerfile")) == "dockerfile",
          "maps exact Dockerfile name")
    check(SyntaxLanguageResolver.languageName(for: URL(fileURLWithPath: "/x/view.tsx")) == "typescript",
          "maps TSX extension")
    check(SyntaxLanguageResolver.languageName(for: URL(fileURLWithPath: "/x/unknown")) == nil,
          "unknown files use highlighter auto-detection")
}

// MARK: - listDirectory + resolveRootDirectory (real temp dir)

section("listDirectory / resolveRootDirectory")
do {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("myide-selftest-\(UUID().uuidString)")
    try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    try! fm.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
    let fileA = tmp.appendingPathComponent("a.txt")
    try! "a".data(using: .utf8)!.write(to: fileA)
    try! "z".data(using: .utf8)!.write(to: tmp.appendingPathComponent("z.txt"))
    // Should be skipped by the listing.
    try! Data().write(to: tmp.appendingPathComponent(".DS_Store"))

    let entries = FileSystem.listDirectory(tmp)
    check(entries.map(\.name) == ["sub", "a.txt", "z.txt"], "lists dirs-first, skips .DS_Store")
    check(entries.first?.isDirectory == true, "first entry is the directory")

    // resolveRootDirectory
    let expected = tmp.standardizedFileURL.resolvingSymlinksInPath().path
    let viaArg = FileSystem.resolveRootDirectory(arguments: ["prog", tmp.path], currentDirectory: "/")
    check(viaArg?.path == expected, "explicit path arg resolves to directory")

    let viaCwd = FileSystem.resolveRootDirectory(arguments: ["prog", "."], currentDirectory: tmp.path)
    check(viaCwd?.path == expected, "'.' resolves against currentDirectory")

    let viaDefault = FileSystem.resolveRootDirectory(arguments: ["prog"], currentDirectory: tmp.path)
    check(viaDefault?.path == expected, "no arg falls back to currentDirectory")

    let explicitArg = FileSystem.resolveRootDirectoryArgument(arguments: ["prog", tmp.path], currentDirectory: "/")
    check(explicitArg?.path == expected, "explicit-only root argument resolves")

    let noExplicitArg = FileSystem.resolveRootDirectoryArgument(
        arguments: ["prog", "-psn_0_12345"],
        currentDirectory: tmp.path
    )
    check(noExplicitArg == nil, "GUI launch without a path has no explicit root")

    check(FileSystem.resolveRootDirectory(arguments: ["prog", "/no/such/dir/xyz"], currentDirectory: "/") == nil,
          "nonexistent path -> nil")
    check(FileSystem.resolveRootDirectory(arguments: ["prog", fileA.path], currentDirectory: "/") == nil,
          "file (not directory) -> nil")

    // loadForDisplay
    let textFile = tmp.appendingPathComponent("hello.txt")
    try! "hello\nworld".data(using: .utf8)!.write(to: textFile)
    check(FileSystem.loadForDisplay(textFile) == .text("hello\nworld"), "loadForDisplay text file")
    check(FileSystem.loadForDisplay(textFile, maxSize: 3) == .tooLarge(bytes: 11), "loadForDisplay respects size cap")

    let binFile = tmp.appendingPathComponent("blob.bin")
    try! Data([0x00, 0x01, 0x02, 0x03]).write(to: binFile)
    check(FileSystem.loadForDisplay(binFile) == .binary, "loadForDisplay binary file")

    check(FileSystem.loadForDisplay(tmp) == .isDirectory, "loadForDisplay directory -> .isDirectory")

    if case .unreadable = FileSystem.loadForDisplay(tmp.appendingPathComponent("nope.txt")) {
        check(true, "loadForDisplay missing file -> unreadable")
    } else {
        check(false, "loadForDisplay missing file -> unreadable")
    }

    // Symlink pointing at a directory must be classified as a directory (follows the link).
    let linkDir = tmp.appendingPathComponent("linkdir")
    try! fm.createSymbolicLink(at: linkDir, withDestinationURL: tmp.appendingPathComponent("sub"))
    let withLink = FileSystem.listDirectory(tmp)
    check(withLink.first(where: { $0.name == "linkdir" })?.isDirectory == true,
          "symlink to directory classified as directory")
}

// MARK: - ChangeSetDocument (pure assembly, no git)

section("ChangeSetDocument")
do {
    func file(_ path: String, status: GitFileStatus = .modified) -> GitChangedFile {
        GitChangedFile(
            path: path,
            repositoryPath: path,
            url: URL(fileURLWithPath: "/repo/\(path)"),
            oldPath: nil,
            status: status
        )
    }
    let doc = ChangeSetDocument.build(entries: [
        .init(file: file("a.txt"), body: "line1\nline2\n", isPlaceholder: false),
        .init(file: file("b/c.swift", status: .deleted), body: "only\n", isPlaceholder: false),
    ])
    let lines = doc.text.components(separatedBy: "\n")
    check(lines.count == 6, "two sections assemble to six lines")
    check(lines[0] == "\(ChangeSetDocument.expandedHeaderPrefix)a.txt", "first header on line 1")
    check(lines[1] == "line1" && lines[2] == "line2", "body follows header")
    check(lines[3] == "", "blank separator between sections")
    check(lines[4] == "\(ChangeSetDocument.expandedHeaderPrefix)b/c.swift  ·  deleted", "second header carries status suffix")
    check(doc.sections[0].headerLine == 1 && doc.sections[0].bodyStartLine == 2 && doc.sections[0].endLine == 4,
          "first section line ranges")
    check(doc.sections[1].headerLine == 5 && doc.sections[1].endLine == 6, "second section line ranges")
    check(doc.section(containingLine: 3)?.file.path == "a.txt", "line lookup: body line")
    check(doc.section(containingLine: 4)?.file.path == "a.txt", "line lookup: separator belongs to previous section")
    check(doc.section(containingLine: 6)?.file.path == "b/c.swift", "line lookup: last line")
    check(doc.section(containingLine: 7) == nil, "line lookup past end -> nil")
    check(doc.section(containingLine: 0) == nil, "line lookup before start -> nil")
    check(doc.section(for: URL(fileURLWithPath: "/repo/b/c.swift"))?.headerLine == 5, "url lookup finds section")
    check(doc.section(for: URL(fileURLWithPath: "/repo/missing.txt")) == nil, "url lookup misses -> nil")

    // Collapsed sections shrink to a single header line and keep the section map coherent.
    let collapsed = ChangeSetDocument.build(
        entries: [
            .init(file: file("a.txt"), body: "line1\nline2\n", isPlaceholder: false),
            .init(file: file("b/c.swift", status: .deleted), body: "only\n", isPlaceholder: false),
        ],
        collapsedPaths: ["a.txt"]
    )
    let collapsedLines = collapsed.text.components(separatedBy: "\n")
    check(collapsedLines.count == 4, "collapsed section drops its body lines")
    check(collapsedLines[0] == "\(ChangeSetDocument.collapsedHeaderPrefix)a.txt  ·  2 hidden lines",
          "collapsed header shows hidden line count")
    check(ChangeSetDocument.isHeaderLine(collapsedLines[0]) && ChangeSetDocument.isHeaderLine(collapsedLines[2]),
          "both header prefixes are recognized")
    check(collapsed.sections[0].isCollapsed && !collapsed.sections[1].isCollapsed, "collapse flags per section")
    check(collapsed.sections[1].headerLine == 3, "following section shifts up")
    check(collapsed.section(containingLine: 1)?.file.path == "a.txt", "collapsed header still maps to its file")
    check(collapsed.section(containingLine: 4)?.file.path == "b/c.swift", "body after collapsed section maps correctly")
}

// MARK: - SideBySideDocument

section("SideBySideDocument")
do {
    func file(_ path: String, status: GitFileStatus = .modified) -> GitChangedFile {
        GitChangedFile(
            path: path,
            repositoryPath: path,
            url: URL(fileURLWithPath: "/repo/\(path)"),
            oldPath: nil,
            status: status
        )
    }
    let patch = """
    diff --git a/src/x.ts b/src/x.ts
    index 111..222 100644
    --- a/src/x.ts
    +++ b/src/x.ts
    @@ -3,4 +3,5 @@ context
     keep3
    -old4
    +new4
    +new5
     keep5
    @@ -20,2 +21,2 @@
     keep21
    -old21
    +new22
    """

    let doc = SideBySideDocument.build(entries: [
        .init(file: file("src/x.ts"), body: patch, isPlaceholder: false),
    ])
    let left = doc.leftText.components(separatedBy: "\n")
    let right = doc.rightText.components(separatedBy: "\n")

    let headerRows = SideBySideDocument.headerRowCount

    check(left.count == right.count, "left and right have identical row counts")
    check(doc.leftKinds.count == left.count && doc.rightKinds.count == right.count,
          "row metadata covers every row")
    // Header block: empty rows on both sides (a real control is drawn over them).
    check(headerRows == 2, "header block is two rows")
    check(left[0].isEmpty && right[0].isEmpty && doc.leftKinds[0] == .fileHeader && doc.rightKinds[1] == .fileHeader,
          "header rows are empty control placeholders")
    check(!doc.rightText.contains("diff --git") && !doc.rightText.contains("+++"),
          "patch metadata dropped")
    // First body row: context "keep3" on both sides, real line numbers, markers stripped.
    check(left[headerRows] == "keep3" && right[headerRows] == "keep3", "context row mirrored without markers")
    check(doc.leftFileLines[headerRows] == 3 && doc.rightFileLines[headerRows] == 3, "context row carries file lines")
    // Change block pairs old4 against new4.
    check(left[headerRows + 1] == "old4" && right[headerRows + 1] == "new4", "deletion pairs with addition on one row")
    check(doc.leftKinds[headerRows + 1] == .deletion && doc.rightKinds[headerRows + 1] == .addition, "paired row kinds")
    check(doc.leftFileLines[headerRows + 1] == 4 && doc.rightFileLines[headerRows + 1] == 4, "paired row file lines")
    // Surplus addition gets a filler on the left.
    check(left[headerRows + 2].isEmpty && right[headerRows + 2] == "new5", "surplus addition faces a filler")
    check(doc.leftKinds[headerRows + 2] == .filler && doc.rightKinds[headerRows + 2] == .addition, "filler kind on short side")
    check(doc.rightFileLines[headerRows + 2] == 5 && doc.leftFileLines[headerRows + 2] == nil, "filler has no file line")
    // Context realigns; hunk break; second hunk.
    check(doc.rightFileLines[headerRows + 3] == 6, "context after additions realigns to new numbering")
    check(doc.leftKinds[headerRows + 4] == .hunkBreak && left[headerRows + 4] == SideBySideDocument.hunkBreakMarker,
          "hunk boundary rendered as a break row")
    check(doc.leftFileLines[headerRows + 5] == 20 && doc.rightFileLines[headerRows + 5] == 21,
          "second hunk restarts numbering")
    check(left[headerRows + 6] == "old21" && right[headerRows + 6] == "new22", "second hunk change block pairs")

    check(doc.section(containingLine: headerRows + 1)?.file.path == "src/x.ts", "row lookup finds section")
    check(doc.section(forPath: "src/x.ts")?.language == "typescript", "section resolves language")
    check(doc.sections[0].additions == 3 && doc.sections[0].deletions == 2, "section counts +3 −2")
    check(doc.rowRange(forNewFileLines: 4...5, inSectionPath: "src/x.ts") == (headerRows + 2)...(headerRows + 3),
          "comment file lines map back to rows")
    check(doc.rowRange(forNewFileLines: 999...999, inSectionPath: "src/x.ts") == nil,
          "unknown file lines map to no rows")

    // Change navigation stops: GitHub's granularity — the first changed row of each hunk.
    // The fixture has two hunks, so two stops, landing on old4/new4 and old21/new22.
    check(doc.changeJumpTargets() == [headerRows + 2, headerRows + 7],
          "split layout yields one jump target per hunk")

    let unifiedDoc = SideBySideDocument.build(
        entries: [.init(file: file("src/x.ts"), body: patch, isPlaceholder: false)],
        layout: .unified
    )
    // Unified stacks the deletion above its additions; the hunk is still a single stop.
    check(unifiedDoc.changeJumpTargets() == [headerRows + 2, headerRows + 8],
          "unified layout yields one jump target per hunk")

    // Two edit runs separated by context *within* one hunk merge into a single stop —
    // per-row-run stops on a real branch produce hundreds of near-adjacent targets.
    let clusteredPatch = """
    diff --git a/src/y.ts b/src/y.ts
    --- a/src/y.ts
    +++ b/src/y.ts
    @@ -3,5 +3,5 @@
     keep3
    -old4
    +new4
     keep5
    -old6
    +new6
    """
    let clustered = SideBySideDocument.build(
        entries: [.init(file: file("src/y.ts"), body: clusteredPatch, isPlaceholder: false)]
    )
    check(clustered.changeJumpTargets() == [headerRows + 2],
          "edit runs inside one hunk share a single jump target")
    let clusteredUnified = SideBySideDocument.build(
        entries: [.init(file: file("src/y.ts"), body: clusteredPatch, isPlaceholder: false)],
        layout: .unified
    )
    check(clusteredUnified.changeJumpTargets() == [headerRows + 2],
          "unified edit runs inside one hunk share a single jump target")
    check(doc.highlightSpans == [SideBySideDocument.HighlightSpan(
        startLine: headerRows + 1,
        endLine: headerRows + 7,
        language: "typescript"
    )], "highlight span covers the body with the file's language")

    // Unified layout: one column in patch order, deletions inline with old-file line numbers.
    let unified = SideBySideDocument.build(
        entries: [.init(file: file("src/x.ts"), body: patch, isPlaceholder: false)],
        layout: .unified
    )
    let unifiedRows = unified.rightText.components(separatedBy: "\n")
    check(unified.layout == .unified, "unified document remembers its layout")
    check(unifiedRows[headerRows] == "keep3", "unified context row")
    check(unifiedRows[headerRows + 1] == "old4" && unified.rightKinds[headerRows + 1] == .deletion,
          "unified deletion appears inline")
    check(unified.leftFileLines[headerRows + 1] == 4 && unified.rightFileLines[headerRows + 1] == nil,
          "unified deletion carries old-file line only")
    check(unifiedRows[headerRows + 2] == "new4" && unifiedRows[headerRows + 3] == "new5",
          "unified additions follow deletions in patch order")
    // Rows are 1-based: header block, keep3, old4, then the additions.
    check(unified.rowRange(forNewFileLines: 4...5, inSectionPath: "src/x.ts")
          == (headerRows + 3)...(headerRows + 4), "unified comment mapping via new-file lines")
    check(unified.sections[0].additions == 3 && unified.sections[0].deletions == 2,
          "unified section stats match")

    // Collapsed sections shrink to just the header block.
    let collapsed = SideBySideDocument.build(
        entries: [
            .init(file: file("src/x.ts"), body: patch, isPlaceholder: false),
            .init(file: file("b.txt"), body: " ctx\n", isPlaceholder: false),
        ],
        collapsedPaths: ["src/x.ts"]
    )
    check(collapsed.sections[0].isCollapsed && collapsed.sections[0].endLine == headerRows + 1,
          "collapsed section is just its header block (plus separator)")
    check(collapsed.sections[0].hiddenLineCount == 14, "collapsed section reports hidden line count")
    check(collapsed.sections[1].headerLine == headerRows + 2, "next section follows separator row")
    // Section 1 is excluded by collapse; section 2 has no body rows to highlight.
    check(collapsed.highlightSpans.isEmpty, "collapsed sections are not highlighted")
}

// MARK: - TSServerMessageBuffer

section("TSServerMessageBuffer")
do {
    func frame(_ json: String) -> Data {
        Data("Content-Length: \(json.utf8.count)\r\n\r\n\(json)".utf8)
    }

    var buffer = TSServerMessageBuffer()
    let single = buffer.append(frame(#"{"seq":1}"#))
    check(single.count == 1 && String(decoding: single[0], as: UTF8.self) == #"{"seq":1}"#,
          "single complete frame parses")

    // Split across arbitrary chunk boundaries.
    var split = TSServerMessageBuffer()
    let whole = frame(#"{"a":1}"#) + Data("\r\n".utf8) + frame(#"{"b":2}"#)
    var collected: [Data] = []
    for byte in whole {
        collected += split.append(Data([byte]))
    }
    check(collected.count == 2, "byte-by-byte feed yields both frames")
    check(String(decoding: collected[1], as: UTF8.self) == #"{"b":2}"#, "second frame content intact")

    var partial = TSServerMessageBuffer()
    check(partial.append(Data("Content-Length: 100\r\n\r\n{".utf8)).isEmpty, "incomplete body waits")
}

// MARK: - ChangeSetViewStateStore

section("ChangeSetViewStateStore")
do {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("myide-viewstate-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }

    let store = ChangeSetViewStateStore(rootURL: URL(fileURLWithPath: "/repo"), branchName: "feature", storageRoot: tmp)
    check(store.load() == .empty, "missing state loads as empty")

    store.save(ChangeSetViewState(collapsedPaths: ["a.txt", "b/c.ts"], anchorPath: "b/c.ts", anchorLineOffset: 12))
    let loaded = store.load()
    check(loaded.collapsedPaths == ["a.txt", "b/c.ts"], "collapsed paths round-trip")
    check(loaded.anchorPath == "b/c.ts" && loaded.anchorLineOffset == 12, "anchor round-trips")

    let otherBranch = ChangeSetViewStateStore(rootURL: URL(fileURLWithPath: "/repo"), branchName: "main", storageRoot: tmp)
    check(otherBranch.load() == .empty, "state is branch-scoped")
}

// MARK: - ReviewComments

section("ReviewComments")
do {
    let first = ReviewComment(
        filePath: "src/app.ts",
        origin: .diff,
        startLine: 4,
        endLine: 5,
        codeText: "+const x = 1\n+use(x)",
        body: "Rename x to something meaningful."
    )
    let second = ReviewComment(
        filePath: "src/lib.ts",
        origin: .source,
        startLine: 12,
        endLine: 12,
        codeText: "export function greet(name: string): string {",
        body: "Add a doc comment."
    )

    let formatted = ReviewCommentFormatter.format(comments: [first, second])
    check(formatted.hasPrefix("Apply the following 2 code review comments:"), "formatter leads with the ask")
    check(formatted.contains("1. src/app.ts (diff lines 4–5)"), "diff comment labeled with patch lines")
    check(formatted.contains("2. src/lib.ts (line 12)"), "source comment labeled with file line")
    check(formatted.contains("+const x = 1\n+use(x)"), "selected code embedded verbatim")
    check(formatted.contains("Rename x to something meaningful."), "comment body embedded")
    check(ReviewCommentFormatter.format(comments: []).isEmpty, "no comments -> empty string")

    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("myide-comments-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }

    let store = ReviewCommentStore(rootURL: URL(fileURLWithPath: "/repo"), branchName: "feature", storageRoot: tmp)
    check(store.load().isEmpty, "missing comments load as empty")
    store.save([first, second])
    let loaded = store.load()
    check(loaded == [first, second], "comments round-trip through disk")
    check(ReviewCommentStore(rootURL: URL(fileURLWithPath: "/repo"), branchName: "main", storageRoot: tmp)
        .load().isEmpty, "comments are branch-scoped")
}

// MARK: - TSServer live (gated: needs a fixture with node_modules/typescript)
// Run with MYIDE_TS_FIXTURE=/path/to/ts-project to exercise the real tsserver end to end.

section("TSServer live")
if let fixturePath = ProcessInfo.processInfo.environment["MYIDE_TS_FIXTURE"] {
    let fixtureURL = URL(fileURLWithPath: fixturePath, isDirectory: true)
    if let toolchain = TSServer.discoverToolchain(projectRoot: fixtureURL) {
        check(true, "discovers node (\(toolchain.nodeURL.lastPathComponent)) and tsserver")
        do {
            let server = try TSServer(toolchain: toolchain)
            defer { server.shutdown() }
            let mainTS = fixtureURL.appendingPathComponent("src/main.ts").path
            // `greet` on line 2, column 1 of src/main.ts → definition in src/lib.ts line 1.
            let result = server.definition(file: mainTS, line: 2, offset: 1, timeout: 30)
            switch result {
            case .success(let spans):
                check(spans.first?.file.hasSuffix("src/lib.ts") == true, "definition resolves to src/lib.ts")
                check(spans.first?.line == 1, "definition points at the declaration line")
            case .failure(let error):
                check(false, "definition lookup succeeded (\(error))")
            }
            // Import specifier: clicking `./lib` on line 1 should land in lib.ts too.
            let importResult = server.definition(file: mainTS, line: 1, offset: 25, timeout: 30)
            if case .success(let spans) = importResult {
                check(spans.first?.file.hasSuffix("lib.ts") == true, "import specifier resolves to the module file")
            } else {
                check(false, "import specifier resolves to the module file")
            }

            // References from the declaration: `greet` in lib.ts line 1 col 17 is the decl;
            // main.ts uses it three times (import + two calls).
            let libTS = fixtureURL.appendingPathComponent("src/lib.ts").path
            let refsResult = server.references(file: libTS, line: 1, offset: 17, timeout: 30)
            if case .success(let payload) = refsResult {
                check(payload.symbolName == "greet", "references reports the symbol name")
                let usages = payload.references.filter { !$0.isDefinition }
                check(usages.count >= 2, "references finds usages beyond the declaration")
                check(payload.references.contains { $0.isDefinition && $0.file.hasSuffix("lib.ts") },
                      "references flags the declaration")
                check(usages.allSatisfy { $0.file.hasSuffix("main.ts") }, "usages point at the caller file")
            } else {
                check(false, "references lookup succeeds")
            }
        } catch {
            check(false, "tsserver spawns (\(error))")
        }
    } else {
        check(false, "discovers node and tsserver for fixture")
    }
} else {
    print("  skip set MYIDE_TS_FIXTURE to run against a real tsserver")
}

// MARK: - GitChangeSet

section("GitChangeSet")
do {
    let root = URL(fileURLWithPath: "/")
    guard runGit(["--version"], in: root)?.status == 0 else {
        print("  skip git unavailable")
        print("")
        if failures == 0 {
            print("PASS — all self-tests passed")
            exit(0)
        } else {
            print("FAIL — \(failures) self-test(s) failed")
            exit(1)
        }
    }

    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("myide-git-selftest-\(UUID().uuidString)")
    try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    let initialized = runGit(["init", "-b", "main"], in: tmp)?.status == 0
    if initialized {
        check(true, "git init main")
    } else {
        checkGit(["init"], in: tmp, "git init")
        checkGit(["checkout", "-b", "main"], in: tmp, "git checkout main")
    }
    checkGit(["config", "user.email", "selftest@example.com"], in: tmp, "git config email")
    checkGit(["config", "user.name", "MyIDE Self Test"], in: tmp, "git config name")
    checkGit(["config", "commit.gpgsign", "false"], in: tmp, "git config signing")

    let nested = tmp.appendingPathComponent("nested", isDirectory: true)
    try! fm.createDirectory(at: nested, withIntermediateDirectories: true)
    try! "old\n".write(to: tmp.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
    try! "base\n".write(to: nested.appendingPathComponent("changed.swift"), atomically: true, encoding: .utf8)

    checkGit(["add", "."], in: tmp, "git add initial")
    checkGit(["commit", "-m", "initial"], in: tmp, "git commit initial")
    checkGit(["checkout", "-b", "feature"], in: tmp, "git checkout feature")

    try! "changed\n".write(to: nested.appendingPathComponent("changed.swift"), atomically: true, encoding: .utf8)
    checkGit(["add", "nested/changed.swift"], in: tmp, "git add branch change")
    checkGit(["commit", "-m", "feature change"], in: tmp, "git commit branch change")

    try! "draft\n".write(to: tmp.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
    checkGit(["rm", "old.txt"], in: tmp, "git rm old file")

    if case .repository(let context) = GitChangeSet.load(for: tmp) {
        let paths = Set(context.files.map(\.path))
        let statuses = Dictionary(uniqueKeysWithValues: context.files.map { ($0.path, $0.status) })
        check(context.branchName == "feature", "detects current branch")
        check(context.baseRef == "main", "detects local base branch")
        check(paths == ["added.txt", "nested/changed.swift", "old.txt"], "combines branch diff and worktree status")
        check(statuses["added.txt"] == .untracked, "marks untracked files")
        check(statuses["nested/changed.swift"] == .modified, "marks branch-modified files")
        check(statuses["old.txt"] == .deleted, "marks deleted files")

        let changedFile = nested.appendingPathComponent("changed.swift")
        if case .diff(let diff) = GitChangeSet.loadDiff(for: changedFile, in: context) {
            check(diff.patch.contains("-base"), "diff includes removed branch-base line")
            check(diff.patch.contains("+changed"), "diff includes added branch line")
        } else {
            check(false, "loads tracked file diff")
        }

        if case .diff(let diff) = GitChangeSet.loadDiff(for: tmp.appendingPathComponent("added.txt"), in: context) {
            check(diff.patch.contains("+draft"), "diff includes untracked file contents")
        } else {
            check(false, "loads untracked file diff")
        }

        if case .diff(let diff) = GitChangeSet.loadDiff(for: tmp.appendingPathComponent("old.txt"), in: context) {
            check(diff.patch.contains("-old"), "diff includes deleted file contents")
        } else {
            check(false, "loads deleted file diff")
        }
    } else {
        check(false, "loads Git repository change context")
    }

    if case .repository(let nestedContext) = GitChangeSet.load(for: nested) {
        check(nestedContext.files.map(\.path) == ["changed.swift"], "filters changes to opened subdirectory")
    } else {
        check(false, "loads nested Git change context")
    }

    // Combined change-set document over the same repo.
    if case .repository(let context) = GitChangeSet.load(for: tmp) {
        let document = GitChangeSet.loadDocument(for: context)
        check(document.sections.count == context.files.count, "document has one section per changed file")
        check(document.sections.map(\.file.path) == context.files.map(\.path), "document sections preserve sidebar order")
        check(document.text.contains("\(ChangeSetDocument.expandedHeaderPrefix)added.txt"), "document contains untracked file header")
        check(document.text.contains("+draft"), "document embeds untracked file patch")
        check(document.text.contains("-old"), "document embeds deleted file patch")

        if let section = document.section(for: nested.appendingPathComponent("changed.swift")) {
            check(document.section(containingLine: section.headerLine)?.file.path == section.file.path,
                  "header line maps back to its section")
            check(document.section(containingLine: section.bodyStartLine)?.file.path == section.file.path,
                  "body line maps back to its section")
        } else {
            check(false, "document section lookup by URL")
        }

        // Whole-file texts captured for line-mapped syntax highlighting.
        let entries = GitChangeSet.loadDocumentEntries(for: context)
        if let changed = entries.first(where: { $0.file.path == "nested/changed.swift" }) {
            check(changed.oldText?.contains("base") == true, "entry captures base version text")
            check(changed.newText?.contains("changed") == true, "entry captures working tree text")
        } else {
            check(false, "entry captures file texts")
        }
        check(entries.first(where: { $0.file.path == "added.txt" })?.oldText == nil,
              "untracked file has no base text")
        check(entries.first(where: { $0.file.path == "old.txt" })?.newText == nil,
              "deleted file has no working tree text")
    } else {
        check(false, "reloads context for document tests")
    }

    // Commit picker source: the branch's commits since the discovered base, newest first.
    let listed = GitChangeSet.listCommits(for: tmp)
    check(listed.count == 1, "listCommits returns only the branch's commits")
    check(listed.first?.subject == "feature change", "listCommits captures the subject")
    check(listed.first.map { $0.sha.hasPrefix($0.shortSHA) } == true, "listCommits pairs sha and short sha")

    // Scoped loads: exactly one commit, or everything since an explicit base.
    // Fixture at this point: commit 1 = {old.txt, nested/changed.swift(base)} on main;
    // commit 2 (feature, HEAD) changed nested/changed.swift; the working tree has
    // added.txt untracked and old.txt deleted.
    let headSha = runGit(["rev-parse", "HEAD"], in: tmp)?.stdout
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if case .repository(let commitContext) = GitChangeSet.load(for: tmp, scope: .commit("HEAD")) {
        check(commitContext.files.map(\.path) == ["nested/changed.swift"],
              "commit scope lists only that commit's files (no working-tree noise)")
        check(commitContext.scope == .commit(headSha), "commit scope pins the resolved SHA")
        check(commitContext.commitSummary?.contains("feature change") == true,
              "commit scope captures the commit summary")

        let document = GitChangeSet.loadDocument(for: commitContext)
        check(document.text.contains("+changed") && document.text.contains("-base"),
              "commit-scoped document embeds exactly that commit's patch")
        check(!document.text.contains("added.txt"), "commit-scoped document omits untracked files")

        let entries = GitChangeSet.loadDocumentEntries(for: commitContext)
        check(entries.first?.newText == "changed\n",
              "commit scope reads the new side from the commit, not the disk")
    } else {
        check(false, "loads commit-scoped context")
    }

    // A root commit has no parent: it diffs against the empty tree, so its files are added.
    let rootSha = runGit(["rev-parse", "HEAD^"], in: tmp)?.stdout
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if case .repository(let rootCommitContext) = GitChangeSet.load(for: tmp, scope: .commit(rootSha)) {
        check(Set(rootCommitContext.files.map(\.path)) == ["old.txt", "nested/changed.swift"],
              "root-commit scope lists the initial files")
        check(rootCommitContext.files.allSatisfy { $0.status == .added },
              "root-commit files diff against the empty tree as added")
    } else {
        check(false, "loads root-commit-scoped context")
    }

    if case .repository(let sinceContext) = GitChangeSet.load(for: tmp, scope: .since("main")) {
        check(sinceContext.baseRef == "main", "since scope uses the literal base ref")
        let paths = Set(sinceContext.files.map(\.path))
        check(paths.contains("nested/changed.swift") && paths.contains("added.txt"),
              "since scope includes branch and working-tree changes")
    } else {
        check(false, "loads since-scoped context")
    }

    if case .notRepository(let message) = GitChangeSet.load(for: tmp, scope: .commit("no-such-ref")) {
        check(message.contains("no-such-ref"), "unknown commit ref surfaces as a load error")
    } else {
        check(false, "unknown commit ref surfaces as a load error")
    }
    if case .notRepository(let message) = GitChangeSet.load(for: tmp, scope: .since("no-such-ref")) {
        check(message.contains("no-such-ref"), "unknown base ref surfaces as a load error")
    } else {
        check(false, "unknown base ref surfaces as a load error")
    }

    // Regression: diffs larger than the ~64 KB pipe buffer used to deadlock runGit
    // (waitUntilExit before draining the pipe). This check *hangs* on regression.
    let bigLine = String(repeating: "x", count: 120) + "\n"
    try! String(repeating: bigLine, count: 3000) // ~360 KB
        .write(to: tmp.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
    if case .repository(let bigContext) = GitChangeSet.load(for: tmp),
       case .diff(let bigDiff) = GitChangeSet.loadDiff(for: tmp.appendingPathComponent("big.txt"), in: bigContext) {
        check(bigDiff.patch.utf8.count > 64 * 1024, "large untracked diff loads past the 64 KB pipe buffer")
    } else {
        check(false, "large untracked diff loads past the 64 KB pipe buffer")
    }
}

print("")
if failures == 0 {
    print("PASS — all self-tests passed")
    exit(0)
} else {
    print("FAIL — \(failures) self-test(s) failed")
    exit(1)
}
