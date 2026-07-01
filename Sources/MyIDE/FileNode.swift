import Foundation
import Combine
import MyIDECore

/// A node in the sidebar tree. Filesystem-backed directories keep `children == nil` until the
/// folder is expanded, then read once and cache. Git change trees are built up front from the
/// already-filtered changed paths.
///
/// `@MainActor` so `children` (an `@Published` observed by the UI) is only mutated on the main
/// thread; the actual directory read is dispatched off-main so a huge folder can't freeze the UI.
@MainActor
final class FileNode: Identifiable, ObservableObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    let changeStatus: GitFileStatus?
    let isExpandedByDefault: Bool

    /// `nil` = not loaded yet. A loaded directory has an array (possibly empty).
    @Published private(set) var children: [FileNode]?
    private var isLoading = false

    nonisolated var id: URL { url }

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        children: [FileNode]? = nil,
        changeStatus: GitFileStatus? = nil,
        isExpandedByDefault: Bool = false
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.changeStatus = changeStatus
        self.isExpandedByDefault = isExpandedByDefault
        self.children = children
    }

    convenience init(entry: DirectoryEntry) {
        self.init(url: entry.url, name: entry.name, isDirectory: entry.isDirectory)
    }

    /// Builds the root node for a directory URL.
    static func root(_ url: URL) -> FileNode {
        FileNode(url: url, name: url.lastPathComponent, isDirectory: true)
    }

    /// Builds an empty root whose children are already loaded. Useful for loading/empty states.
    static func emptyRoot(_ url: URL) -> FileNode {
        FileNode(url: url, name: displayName(for: url), isDirectory: true, children: [])
    }

    /// Builds a static, pre-expanded tree from Git changed paths instead of walking the disk.
    static func changeRoot(_ url: URL, files: [GitChangedFile]) -> FileNode {
        let builder = ChangeTreeBuilder(name: displayName(for: url), url: url, isDirectory: true)
        for file in files {
            builder.insert(file)
        }
        return builder.makeNode()
    }

    /// Loads immediate children exactly once, reading the directory off the main thread.
    /// Safe to call repeatedly — the in-flight guard prevents duplicate reads.
    func loadChildrenIfNeeded() {
        guard isDirectory, children == nil, !isLoading else { return }
        isLoading = true
        let url = self.url
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                FileSystem.listDirectory(url)
            }.value
            self.children = entries.map(FileNode.init(entry:))
            self.isLoading = false
        }
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

@MainActor
private final class ChangeTreeBuilder {
    let name: String
    var url: URL
    var isDirectory: Bool
    var changeStatus: GitFileStatus?
    var children: [String: ChangeTreeBuilder] = [:]

    init(name: String, url: URL, isDirectory: Bool) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
    }

    func insert(_ file: GitChangedFile) {
        let components = file.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        var node = self
        var parentURL = url
        for (index, component) in components.enumerated() {
            let isLeaf = index == components.count - 1
            let childURL = isLeaf ? file.url : parentURL.appendingPathComponent(component, isDirectory: true)
            let child = node.children[component] ?? ChangeTreeBuilder(
                name: component,
                url: childURL,
                isDirectory: !isLeaf
            )
            child.url = childURL
            child.isDirectory = !isLeaf
            if isLeaf {
                child.changeStatus = file.status
            }
            node.children[component] = child
            node = child
            parentURL = childURL
        }
    }

    func makeNode() -> FileNode {
        let sortedChildren = children.values.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return FileNode(
            url: url,
            name: name,
            isDirectory: isDirectory,
            children: isDirectory ? sortedChildren.map { $0.makeNode() } : nil,
            changeStatus: changeStatus,
            isExpandedByDefault: true
        )
    }
}
