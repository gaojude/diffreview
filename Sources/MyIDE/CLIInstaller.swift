import Combine
import Foundation

/// Installs the launcher embedded in DiffReview.app into a conventional PATH location. The app is
/// not sandboxed; when `/usr/local/bin` is protected, macOS supplies its standard administrator
/// authentication dialog through AppleScript's `with administrator privileges` facility.
@MainActor
final class CLIInstaller: ObservableObject {
    enum State: Equatable {
        case available(existingCommand: Bool)
        case installed
        case installing
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .available(existingCommand: false)

    let destinationURL = URL(fileURLWithPath: "/usr/local/bin/diffreview")

    private var bundledCLIURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/diffreview-cli", isDirectory: false)
    }

    init() {
        refresh()
    }

    func refresh() {
        guard FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) else {
            state = .unavailable("The command line tool is not included in this build of DiffReview.")
            return
        }

        if installedCommandMatchesCurrentApp() {
            state = .installed
        } else {
            state = .available(existingCommand: commandExistsAtDestination())
        }
    }

    func install() {
        guard case .available = state else { return }
        state = .installing

        let source = bundledCLIURL
        let destination = destinationURL
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Self.install(source: source, destination: destination)
            }.value

            switch result {
            case .success:
                refresh()
                if state != .installed {
                    state = .failed("The command was installed, but DiffReview could not verify it.")
                }
            case .failure(let error):
                state = .failed(error.localizedDescription)
            }
        }
    }

    func retryInstall() {
        guard case .failed = state else { return }
        refresh()
        install()
    }

    private func installedCommandMatchesCurrentApp() -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: destinationURL.path) else {
            return false
        }
        let targetURL: URL
        if target.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: target)
        } else {
            targetURL = destinationURL.deletingLastPathComponent().appendingPathComponent(target)
        }
        return targetURL.standardizedFileURL.resolvingSymlinksInPath()
            == bundledCLIURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func commandExistsAtDestination() -> Bool {
        FileManager.default.fileExists(atPath: destinationURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: destinationURL.path)) != nil
    }

    nonisolated private static func install(source: URL, destination: URL) -> Result<Void, Error> {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()

        do {
            if fileManager.isWritableFile(atPath: parent.path) {
                try replaceSymlink(source: source, destination: destination)
                return .success(())
            }

            let command = [
                "/bin/mkdir -p \(shellQuote(parent.path))",
                "/bin/ln -sfn \(shellQuote(source.path)) \(shellQuote(destination.path))",
            ].joined(separator: " && ")
            let appleScript = "do shell script \(appleScriptString(command)) with administrator privileges"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw CLIInstallError.installFailed(
                    detail?.isEmpty == false ? detail! : "Administrator authorization was cancelled."
                )
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func replaceSymlink(source: URL, destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    nonisolated private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private enum CLIInstallError: LocalizedError {
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .installFailed(let detail): return detail
        }
    }
}
