import SwiftUI
import MyIDECore

/// Left sidebar: a branch-scoped tree of changed paths. `List(selection:)` gives native
/// highlight and arrow-key navigation for free; each file row is tagged with its URL so
/// selection flows to the content pane.
struct FileTreeView: View {
    @ObservedObject var rootNode: FileNode
    let changeTreeState: AppState.ChangeTreeState
    @Binding var selection: URL?

    var body: some View {
        List(selection: $selection) {
            Section {
                switch changeTreeState {
                case .loading:
                    SidebarMessageRow(text: "Loading changes", systemImage: "arrow.triangle.2.circlepath")
                case .notRepository(let message):
                    SidebarMessageRow(text: message, systemImage: "exclamationmark.triangle")
                case .loaded(let context):
                    if context.files.isEmpty {
                        SidebarMessageRow(text: "No changed files", systemImage: "checkmark.circle")
                    } else if let children = rootNode.children {
                        ForEach(children) { FileNodeRow(node: $0) }
                    }
                }
            } header: {
                ChangeScopeHeader(rootName: rootNode.name, state: changeTreeState)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar")
        .onAppear { rootNode.loadChildrenIfNeeded() }
    }
}

/// A single recursive row. Branch-change directories are preloaded and expanded by default;
/// fallback filesystem directories still load children the first time they expand.
private struct FileNodeRow: View {
    @ObservedObject var node: FileNode
    @State private var isExpanded: Bool

    init(node: FileNode) {
        self.node = node
        _isExpanded = State(initialValue: node.isExpandedByDefault)
    }

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $isExpanded) {
                if let children = node.children {
                    ForEach(children) { FileNodeRow(node: $0) }
                }
            } label: {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(node.name, systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(node.url.path)
            }
            .selectionDisabled(true)
            .onChange(of: isExpanded) { _, expanded in
                if expanded { node.loadChildrenIfNeeded() }
            }
        } else {
            HStack(spacing: 6) {
                Label(node.name, systemImage: icon(for: node.name))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let status = node.changeStatus {
                    ChangeStatusBadge(status: status)
                }
            }
                .tag(node.url)
                .selectionDisabled(false)
                .accessibilityIdentifier(node.url.path)
        }
    }

    /// Lightweight icon selection by extension — purely cosmetic.
    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "c", "h", "m", "cpp", "rs", "go", "py", "rb", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs":
            return "curlybraces"
        case "json", "yml", "yaml", "toml", "xml", "plist":
            return "list.bullet.rectangle"
        case "md", "markdown", "txt", "rst":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "icns":
            return "photo"
        default:
            return "doc.text"
        }
    }
}

private struct ChangeScopeHeader: View {
    let rootName: String
    let state: AppState.ChangeTreeState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "arrow.triangle.branch")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .textCase(nil)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var title: String {
        switch state {
        case .loading:
            return "Branch Changes"
        case .notRepository:
            return "No Git Branch"
        case .loaded(let context):
            return context.branchName
        }
    }

    private var subtitle: String {
        switch state {
        case .loading:
            return rootName
        case .notRepository:
            return rootName
        case .loaded(let context):
            let comparison = context.baseRef.map { "vs \($0)" } ?? "working tree"
            let count = context.files.count == 1 ? "1 changed file" : "\(context.files.count) changed files"
            return "\(comparison) • \(count)"
        }
    }
}

private struct SidebarMessageRow: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .selectionDisabled(true)
    }
}

private struct ChangeStatusBadge: View {
    let status: GitFileStatus

    var body: some View {
        Text(shortLabel)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: 18, height: 16)
            .background(background, in: .rect(cornerRadius: 4))
            .help(longLabel)
            .accessibilityLabel(longLabel)
    }

    private var shortLabel: String {
        switch status {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "?"
        case .typeChanged: return "T"
        case .conflicted: return "!"
        case .unknown: return "-"
        }
    }

    private var longLabel: String {
        switch status {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .untracked: return "Untracked"
        case .typeChanged: return "Type changed"
        case .conflicted: return "Conflicted"
        case .unknown(let code): return "Git status \(code)"
        }
    }

    private var foreground: Color {
        switch status {
        case .added, .untracked:
            return .green
        case .deleted:
            return .red
        case .renamed, .copied:
            return .purple
        case .conflicted:
            return .orange
        default:
            return .blue
        }
    }

    private var background: Color {
        foreground.opacity(0.14)
    }
}
