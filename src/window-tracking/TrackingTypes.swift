import Foundation

/// **A pid plus the generation AltTab assigned it.** macOS reuses pids, so a bare pid cannot say whether a
/// callback belongs to the process that is running now or to the one that died a second ago. Every rule keyed
/// on identity keys on this instead.
struct ProcessGeneration: Hashable, Comparable {
    let pid: Int32
    let generation: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid ? lhs.generation < rhs.generation : lhs.pid < rhs.pid
    }
}

/// A window, qualified by the process generation that owns it. A wid alone is not an identity: the
/// WindowServer reuses those too.
struct WindowIdentity: Hashable, Comparable {
    let process: ProcessGeneration
    let wid: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.process == rhs.process ? lhs.wid < rhs.wid : lhs.process < rhs.process
    }
}

/// **Arrival order, allocated when evidence reaches the model.** `AttentionModel` compares these per process
/// and nowhere else: a lower sequence never overwrites a higher one for the same process, which is what makes
/// a bounded read that lands after the app already spoke lose to the app.
struct IngressSequence: RawRepresentable, Hashable, Comparable {
    let rawValue: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A monotonic clock reading, for the AX observer health policy's budgets and cooldowns. Monotonic because a
/// wall-clock jump must not make a retry look overdue or a cooldown look expired.
struct MonotonicTimestamp: RawRepresentable, Hashable, Comparable {
    let rawValue: UInt64
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Who told us something. Telemetry only: a disagreement has to be attributable to a channel rather than to
/// "focus" in general.
enum TrackingProvider: Hashable {
    case windowServer
    case workspace
    case accessibility
    case annotatedSession
    case altTab
}

/// What entitles a call to move the window order. See `WindowEventReducer.applyFocusAndBump` and
/// `AttentionOrderSpecs.md`.
enum AttentionWriteSource: Equatable {
    /// the attention reducer committed a decision — the only source that may claim the user moved
    case attentionReducer
    /// the order had to change for a reason that is not about the user: the front window closed and
    /// something must take its place, or a tab group's representative changed
    case structuralRepair
}
