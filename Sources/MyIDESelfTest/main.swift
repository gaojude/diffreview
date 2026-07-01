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
}

print("")
if failures == 0 {
    print("PASS — all self-tests passed")
    exit(0)
} else {
    print("FAIL — \(failures) self-test(s) failed")
    exit(1)
}
