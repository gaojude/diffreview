import Foundation

struct AssistantPersistedState: Codable, Equatable {
    var selectedThreadID: SelectionChatThread.ID?
    var threads: [SelectionChatThread]
    var fixes: [PromptFixItem]

    static let empty = AssistantPersistedState(
        selectedThreadID: nil,
        threads: [],
        fixes: []
    )
}

struct AssistantPersistenceStore: Equatable {
    let id: String
    private let fileURL: URL

    init(rootURL: URL, branchName: String, storageRoot: URL? = nil) {
        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let scope = "\(resolvedRoot.path)#\(branchName)"
        self.id = Self.stableHexID(for: scope)

        let baseURL = storageRoot ?? Self.defaultStorageRoot()
        self.fileURL = baseURL
            .appendingPathComponent(id, isDirectory: false)
            .appendingPathExtension("json")
    }

    func load() -> AssistantPersistedState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .empty
        }
        return (try? JSONDecoder().decode(AssistantPersistedState.self, from: data)) ?? .empty
    }

    func saveThreads(_ threads: [SelectionChatThread], selectedThreadID: SelectionChatThread.ID?) {
        var state = load()
        state.threads = threads
        state.selectedThreadID = selectedThreadID
        save(state)
    }

    func saveFixes(_ fixes: [PromptFixItem]) {
        var state = load()
        state.fixes = fixes
        save(state)
    }

    func save(_ state: AssistantPersistedState) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            #if DEBUG
            fputs("MyIDE assistant persistence failed: \(error)\n", stderr)
            #endif
        }
    }

    private static func defaultStorageRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MyIDE/AssistantState", isDirectory: true)
    }

    private static func stableHexID(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
