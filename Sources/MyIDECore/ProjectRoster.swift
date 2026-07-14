import Foundation

/// The ordered set of projects attached to the window, plus which one is showing. Pure
/// list/selection policy — no AppKit, no file I/O — so `MyIDESelfTest` can pin down the
/// attach/close/switch behavior directly. IDs are resolved root paths; `AppSession` maps
/// them back to live project state.
public struct ProjectRoster: Equatable, Sendable {
    public private(set) var ids: [String] = []
    public private(set) var activeID: String?

    public init() {}

    public var count: Int { ids.count }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Attaching always activates. Returns `true` when the id is new; `false` when it was
    /// already attached (re-running `diffreview` on an open project just switches to it).
    @discardableResult
    public mutating func attach(_ id: String) -> Bool {
        defer { activeID = id }
        if ids.contains(id) { return false }
        ids.append(id)
        return true
    }

    /// Ignores unknown ids so a stale UI action can never select a project that isn't attached.
    public mutating func activate(_ id: String) {
        guard ids.contains(id) else { return }
        activeID = id
    }

    /// Closing the active project reveals its right neighbor (like browser tabs); the last
    /// project falls back to its left neighbor. Closing an inactive project changes nothing
    /// about what's showing.
    public mutating func close(_ id: String) {
        guard let index = ids.firstIndex(of: id) else { return }
        ids.remove(at: index)
        guard activeID == id else { return }
        if ids.isEmpty {
            activeID = nil
        } else {
            activeID = ids[min(index, ids.count - 1)]
        }
    }

    /// Steps the active project forward/backward through the strip, wrapping at the ends.
    public mutating func activateAdjacent(forward: Bool) {
        guard ids.count > 1,
              let activeID,
              let index = ids.firstIndex(of: activeID) else { return }
        let offset = forward ? 1 : ids.count - 1
        self.activeID = ids[(index + offset) % ids.count]
    }
}
