import Cocoa

/// Main-thread inventory of every WindowServer surface from the latest all-Space snapshot. Keeping this
/// separate from `Windows.byWindowId` is essential: a physical background-tab row is not yet a tracked
/// switch destination and must not prevent inactive-tab AX adoption from looking for it.
enum WindowSurfaceInventory {
    private(set) static var byWindowId = [CGWindowID: WsRawWindow]()

    /// Whether a whole-machine sweep has ever landed here. Until it has, this holds only the handful of rows
    /// single-window discoveries happened to upsert, so it cannot answer "what else does this app have on
    /// screen?" — a question `Applications.discoverInactiveTabs` must not get a partial answer to (an empty
    /// `others` waves every candidate through). After the first `replace` it is a SUPERSET of the on-screen
    /// list: every app-level surface on every Space, not just the current one.
    private(set) static var hasFullSnapshot = false

    static func replace(_ rows: [WsRawWindow]) {
        byWindowId = Dictionary(uniqueKeysWithValues: rows.map { ($0.wid, $0) })
        hasFullSnapshot = true
    }

    /// The visible surfaces of one process, for the callers that need to reason about an app's own window
    /// layout. Returns nil before the first full sweep rather than a misleadingly short list.
    static func visibleSurfaces(pid: pid_t) -> [WsRawWindow]? {
        guard hasFullSnapshot else { return nil }
        return byWindowId.values.filter { $0.pid == pid && WsWindowState.isVisible($0) }
    }

    static func upsert(_ rows: [WsRawWindow]) {
        for row in rows { byWindowId[row.wid] = row }
    }

    static func remove(pid: pid_t) {
        byWindowId = byWindowId.filter { $0.value.pid != pid }
    }

    static func remove(_ wid: CGWindowID) {
        byWindowId.removeValue(forKey: wid)
    }

    static func raw(_ wid: CGWindowID) -> WsRawWindow? {
        byWindowId[wid]
    }

    /// Follow WindowServer parent links while they stay inside one process. Cycles and missing/cross-process
    /// parents stop at the last trustworthy surface instead of inventing a relationship.
    static func representativeWid(_ wid: CGWindowID) -> CGWindowID {
        guard let first = byWindowId[wid] else { return wid }
        var current = first
        var visited = Set([wid])
        while current.parentWid != 0,
              !visited.contains(current.parentWid),
              let parent = byWindowId[current.parentWid], parent.pid == first.pid {
            visited.insert(parent.wid)
            current = parent
        }
        return current.wid
    }
}
