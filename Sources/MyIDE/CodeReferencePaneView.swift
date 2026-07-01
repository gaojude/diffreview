import SwiftUI
import MyIDECore

struct CodeReferencePaneView: View {
    let rootURL: URL
    let reference: CodeReference?
    let fontSize: CGFloat
    var onClose: () -> Void = {}

    @State private var state: LoadState = .empty
    @State private var resolvedURL: URL?
    @State private var resolvedPath: String?
    @StateObject private var disabledChat = SelectionChatController()

    enum LoadState: Equatable {
        case empty
        case loading
        case text(String)
        case message(String)
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
            header
                .padding(.horizontal, 10)
                .padding(.top, 8)
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: reference?.id) {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: reference == nil ? "doc.text.magnifyingglass" : "link")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if reference != nil {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close reference pane")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .glassEffect(.regular, in: .rect(cornerRadius: 23))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .empty:
            placeholder("Click a code reference in chat", systemImage: "link")
                .accessibilityIdentifier("reference-empty-state")
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text(let text):
            CodeTextView(
                text: text,
                fileURL: resolvedURL,
                topInset: 62,
                fontSize: fontSize,
                selectionChat: disabledChat,
                allowsSelectionChat: false,
                focusedLineRange: reference?.lineRange
            )
            .accessibilityIdentifier("reference-content-view")
        case .message(let message):
            placeholder(message, systemImage: "exclamationmark.triangle")
                .accessibilityIdentifier("reference-message")
        }
    }

    private var title: String {
        guard let reference else { return "Reference" }
        if let resolvedURL {
            return resolvedURL.lastPathComponent
        }
        return URL(fileURLWithPath: reference.path).lastPathComponent
    }

    private var subtitle: String {
        guard let reference else { return "Waiting for a chat citation" }
        let path = resolvedPath ?? reference.path
        guard let lineRange = reference.lineRange else { return path }
        if lineRange.lowerBound == lineRange.upperBound {
            return "\(path) line \(lineRange.lowerBound)"
        }
        return "\(path) lines \(lineRange.lowerBound)-\(lineRange.upperBound)"
    }

    @MainActor
    private func load() async {
        guard let reference else {
            state = .empty
            resolvedURL = nil
            resolvedPath = nil
            return
        }

        state = .loading
        let rootURL = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            Self.loadReference(reference: reference, rootURL: rootURL)
        }.value
        if Task.isCancelled { return }

        switch result {
        case .loaded(let loaded):
            resolvedURL = loaded.url
            resolvedPath = loaded.path
            state = .text(loaded.text)
        case .failed(let message):
            resolvedURL = nil
            resolvedPath = nil
            state = .message(message)
        }
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    nonisolated private static func loadReference(reference: CodeReference, rootURL: URL) -> ReferenceLoadResult {
        guard let resolved = resolve(reference: reference, rootURL: rootURL) else {
            return .failed("Could not find \(reference.path).")
        }

        guard let data = try? Data(contentsOf: resolved.url, options: [.mappedIfSafe]) else {
            return .failed("Could not read \(resolved.path).")
        }
        guard !FileSystem.isProbablyBinary(data) else {
            return .failed("\(resolved.path) appears to be binary.")
        }
        return .loaded(LoadedReference(url: resolved.url, path: resolved.path, text: FileSystem.decodeText(data)))
    }

    nonisolated private static func resolve(reference: CodeReference, rootURL: URL) -> LoadedReferenceLocation? {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let trimmed = reference.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }

        let direct = root.appendingPathComponent(trimmed).standardizedFileURL.resolvingSymlinksInPath()
        if direct.path == root.path || direct.path.hasPrefix(root.path + "/"),
           FileManager.default.fileExists(atPath: direct.path) {
            return LoadedReferenceLocation(url: direct, path: trimmed)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return nil
        }

        var matches: [LoadedReferenceLocation] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
            if values.isDirectory == true {
                if ignoredDirectoryNames.contains(name) || name.hasSuffix(".app") {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = relativePath(for: url, root: root)
            guard path == trimmed || path.hasSuffix("/\(trimmed)") || name == trimmed else { continue }
            matches.append(LoadedReferenceLocation(url: url, path: path))
        }

        return matches.sorted { lhs, rhs in
            lhs.path.count == rhs.path.count
                ? lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
                : lhs.path.count < rhs.path.count
        }.first
    }

    nonisolated private static func relativePath(for url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private struct LoadedReference: Sendable {
        let url: URL
        let path: String
        let text: String
    }

    private enum ReferenceLoadResult: Sendable {
        case loaded(LoadedReference)
        case failed(String)
    }

    private struct LoadedReferenceLocation: Sendable {
        let url: URL
        let path: String
    }

    nonisolated private static let ignoredDirectoryNames: Set<String> = [
        ".build", ".git", ".next", ".turbo", ".venv", ".yarn", "DerivedData",
        "Pods", "build", "coverage", "dist", "node_modules", "out", "target",
        "vendor", "venv",
    ]
}
