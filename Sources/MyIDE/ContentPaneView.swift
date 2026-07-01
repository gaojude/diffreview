import SwiftUI
import AppKit
import MyIDECore

/// The right-hand pane. In a Git change set, selecting a file loads its patch off the main
/// thread; outside Git context it falls back to read-only file contents.
///
/// It shows the last *file* that was opened: selecting a folder in the sidebar does not change
/// what's displayed. A minimal floating Liquid Glass header shows the current file's name.
struct ContentPaneView: View {
    let fileURL: URL?
    let changeTreeState: AppState.ChangeTreeState
    var fontSize: CGFloat = FontSizes.default

    @State private var state: LoadState = .empty
    @State private var displayedName: String?   // name of the file currently shown
    @State private var displayedContext: String?

    enum LoadState {
        case empty
        case loading
        case text(String)
        case diff(String)
        case message(String) // placeholder: too large / binary / read error
    }

    var body: some View {
        ZStack(alignment: .top) {
            contentLayer
            floatingHeader
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: fileURL) { await load() } // auto-cancels when the selection changes
    }

    // MARK: - Header (minimal floating Liquid Glass)

    private var floatingHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayedName ?? "No file selected")
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let displayedContext {
                    Text(displayedContext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .glassEffect(.regular, in: .rect(cornerRadius: 23))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var headerIcon: String {
        switch state {
        case .diff:
            return "plus.forwardslash.minus"
        case .empty:
            return "sidebar.left"
        default:
            return "doc.text"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentLayer: some View {
        switch state {
        case .empty:
            glassPlaceholder("Select a file to view its contents", systemImage: "doc.text")
                .accessibilityIdentifier("empty-state")
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let s):
            CodeTextView(text: s, fileURL: fileURL, topInset: 56, fontSize: fontSize)
                .accessibilityIdentifier("content-view")
        case .diff(let s):
            CodeTextView(text: s, fileURL: fileURL, contentKind: .diff, topInset: 62, fontSize: fontSize)
                .accessibilityIdentifier("content-view")
        case .message(let m):
            glassPlaceholder(m, systemImage: "doc")
                .accessibilityIdentifier("content-message")
        }
    }

    private func glassPlaceholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 36)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        // No file selected (or a folder is selected) → keep showing the current file.
        guard let url = fileURL else { return }
        state = displayedName == nil ? .loading : state

        if case .loaded(let context) = changeTreeState {
            let result = await Task.detached(priority: .userInitiated) {
                GitChangeSet.loadDiff(for: url, in: context)
            }.value
            if Task.isCancelled { return }
            displayedName = url.lastPathComponent
            displayedContext = diffContextLabel(for: context)
            state = Self.map(result)
            return
        }

        // loadForDisplay lives in MyIDECore (not main-actor isolated) and does its own stat,
        // so all file access runs off the main thread.
        let result = await Task.detached(priority: .userInitiated) { FileSystem.loadForDisplay(url) }.value
        if Task.isCancelled { return }
        if case .isDirectory = result { return } // folder selected → keep the previous file
        displayedName = url.lastPathComponent
        displayedContext = nil
        state = Self.map(result)
    }

    private static func map(_ load: FileSystem.FileLoad) -> LoadState {
        switch load {
        case .text(let s):          return .text(s)
        case .tooLarge(let bytes):  return .message("File is too large to preview (\(byteString(bytes))).")
        case .binary:               return .message("Binary file — not shown.")
        case .isDirectory:          return .empty // unreachable: handled before map
        case .unreadable(let m):    return .message("Can’t read file: \(m)")
        }
    }

    private static func map(_ load: GitDiffLoadResult) -> LoadState {
        switch load {
        case .diff(let diff):
            return .diff(diff.patch)
        case .noDiff:
            return .message("No diff for this file.")
        case .tooLarge(let bytes):
            return .message("Diff is too large to preview (\(byteString(bytes))).")
        case .fileNotInChangeSet:
            return .message("This file is not part of the current change set.")
        case .unavailable(let message):
            return .message("Can’t load diff: \(message)")
        }
    }

    private func diffContextLabel(for context: GitChangeContext) -> String {
        if let baseRef = context.baseRef {
            return "Diff vs \(baseRef)"
        }
        return "Working tree diff"
    }

    private static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
