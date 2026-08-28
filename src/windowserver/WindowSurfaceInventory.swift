import Cocoa

/// Main-thread inventory of every WindowServer surface from the latest all-Space snapshot. Keeping this
/// separate from `Windows.byWindowId` is essential: a physical background-tab row is not yet a tracked
/// switch destination and must not prevent inactive-tab AX adoption from looking for it.
enum WindowSurfaceInventory {
    private(set) static var byWindowId = [CGWindowID: WsRawWindow]()

    static func replace(_ rows: [WsRawWindow]) {
        byWindowId = Dictionary(uniqueKeysWithValues: rows.map { ($0.wid, $0) })
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
