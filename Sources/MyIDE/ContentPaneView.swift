import SwiftUI
import AppKit
import MyIDECore

/// The right-hand pane. In a Git change set, selecting a file loads its patch off the main
/// thread; outside Git context it falls back to read-only file contents.
///
/// It shows the last *file* that was opened: selecting a folder in the sidebar does not change
/// what's displayed. A minimal floating Liquid Glass header shows the current file's name.
struct ContentPaneView: View {
    let rootURL: URL
    let fileURL: URL?
    let changeTreeState: AppState.ChangeTreeState
    var fontSize: CGFloat = FontSizes.default

    @State private var state: LoadState = .empty
    @State private var displayedName: String?   // name of the file currently shown
    @State private var displayedContext: String?
    @State private var displayedFileURL: URL?
    @State private var selectionContext: CodeSelectionContext?
    @State private var activeReference: CodeReference?
    @StateObject private var selectionChat = SelectionChatController()
    @StateObject private var promptAccumulator = PromptAccumulatorController()
    @State private var assistantTab: AssistantPaneTab = .chat

    enum LoadState {
        case empty
        case loading
        case text(String)
        case diff(String)
        case message(String) // placeholder: too large / binary / read error
    }

    var body: some View {
        HSplitView {
            primaryPane
                .frame(minWidth: 520)
            assistantPane
                .frame(minWidth: 320, idealWidth: 420)
        }
        .onChange(of: fileURL) { _, _ in
            activeReference = nil
        }
        .onChange(of: selectionChat.referenceRequest?.id) { _, _ in
            guard let request = selectionChat.referenceRequest else { return }
            activeReference = request.reference
        }
        .task(id: assistantPersistenceID) {
            configureAssistantPersistence()
        }
    }

    private var assistantPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $assistantTab) {
                Label("Chat", systemImage: "text.bubble")
                    .tag(AssistantPaneTab.chat)
                Label(fixesTabTitle, systemImage: "checklist")
                    .tag(AssistantPaneTab.fixes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            switch assistantTab {
            case .chat:
                SelectionChatPaneView(
                    chat: selectionChat,
                    fontSize: fontSize,
                    onCaptureFix: captureFix
                )
            case .fixes:
                PromptFixListView(
                    accumulator: promptAccumulator,
                    fontSize: fontSize
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var fixesTabTitle: String {
        promptAccumulator.items.isEmpty ? "Fixes" : "Fixes \(promptAccumulator.items.count)"
    }

    @discardableResult
    private func captureFix(proposal: AgentFixProposal, snapshot: PromptFixSnapshot) -> PromptFixItem? {
        let item = promptAccumulator.capture(proposal: proposal, snapshot: snapshot)
        assistantTab = .fixes
        return item
    }

    private var assistantPersistenceID: String {
        "\(rootURL.standardizedFileURL.resolvingSymlinksInPath().path)#\(assistantBranchName)"
    }

    private var assistantBranchName: String {
        switch changeTreeState {
        case .loaded(let context):
            return context.branchName
        case .notRepository:
            return "no-git"
        case .loading:
            return "loading"
        }
    }

    private func configureAssistantPersistence() {
        guard assistantBranchName != "loading" else { return }
        let store = AssistantPersistenceStore(
            rootURL: rootURL,
            branchName: assistantBranchName
        )
        selectionChat.configurePersistence(store: store)
        promptAccumulator.configurePersistence(store: store)
    }

    private enum AssistantPaneTab: Hashable {
        case chat
        case fixes
    }

    private var primaryPane: some View {
        ZStack(alignment: .top) {
            contentLayer
            floatingHeader
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: loadID) { await load() } // auto-cancels when the target changes
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
            if let selectionContext {
                Text(selectionContext.lineLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if activeReference != nil {
                Button {
                    activeReference = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Back to selected change")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .glassEffect(.regular, in: .rect(cornerRadius: 23))
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

    private func askAboutSelection(_ context: CodeSelectionContext?) {
        selectionContext = context
        selectionChat.setContext(context: context, rootURL: rootURL)
    }

    private var loadID: String {
        if let activeReference {
            return "reference:\(activeReference.id)"
        }
        return fileURL?.path ?? "empty"
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
            CodeTextView(
                text: s,
                fileURL: displayedFileURL,
                topInset: 56,
                fontSize: fontSize,
                selectionChat: selectionChat,
                focusedLineRange: activeReference?.lineRange,
                onSelectionChange: selectionDidChange,
                onAskSelection: askAboutSelection
            )
                .accessibilityIdentifier("content-view")
        case .diff(let s):
            CodeTextView(
                text: s,
                fileURL: displayedFileURL,
                contentKind: .diff,
                topInset: 62,
                fontSize: fontSize,
                selectionChat: selectionChat,
                onSelectionChange: selectionDidChange,
                onAskSelection: askAboutSelection
            )
                .accessibilityIdentifier("content-view")
        case .message(let m):
            glassPlaceholder(m, systemImage: "doc")
                .accessibilityIdentifier("content-message")
        }
    }

    private func selectionDidChange(_ context: CodeSelectionContext?) {
        selectionContext = context
        selectionChat.setContext(context: context, rootURL: rootURL)
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
        if let activeReference {
            await load(reference: activeReference)
            return
        }

        // No file selected (or a folder is selected) → keep showing the current file.
        guard let url = fileURL else { return }
        state = displayedName == nil ? .loading : state

        if case .loaded(let context) = changeTreeState {
            let result = await Task.detached(priority: .userInitiated) {
                GitChangeSet.loadDiff(for: url, in: context)
            }.value
            if Task.isCancelled { return }
            selectionContext = nil
            displayedName = url.lastPathComponent
            displayedContext = diffContextLabel(for: context)
            displayedFileURL = url
            state = Self.map(result)
            return
        }

        // loadForDisplay lives in MyIDECore (not main-actor isolated) and does its own stat,
        // so all file access runs off the main thread.
        let result = await Task.detached(priority: .userInitiated) { FileSystem.loadForDisplay(url) }.value
        if Task.isCancelled { return }
        if case .isDirectory = result { return } // folder selected → keep the previous file
        selectionContext = nil
        displayedName = url.lastPathComponent
        displayedContext = nil
        displayedFileURL = url
        state = Self.map(result)
    }

    @MainActor
    private func load(reference: CodeReference) async {
        state = .loading
        let rootURL = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            CodeReferenceResolver.load(reference: reference, rootURL: rootURL)
        }.value
        if Task.isCancelled { return }

        selectionContext = nil
        switch result {
        case .loaded(let loaded):
            displayedName = loaded.url.lastPathComponent
            displayedContext = referenceContextLabel(path: loaded.path, reference: reference)
            displayedFileURL = loaded.url
            state = .text(loaded.text)
        case .failed(let message):
            displayedName = URL(fileURLWithPath: reference.path).lastPathComponent
            displayedContext = "Reference from chat"
            displayedFileURL = nil
            state = .message(message)
        }
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

    private func referenceContextLabel(path: String, reference: CodeReference) -> String {
        guard let lineRange = reference.lineRange else {
            return path
        }
        if lineRange.lowerBound == lineRange.upperBound {
            return "\(path) line \(lineRange.lowerBound)"
        }
        return "\(path) lines \(lineRange.lowerBound)-\(lineRange.upperBound)"
    }

    private static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
