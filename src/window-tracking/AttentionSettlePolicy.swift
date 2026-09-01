import Foundation
import CoreGraphics

/// **Which of an app's answers actually commits.**
///
/// An app raising all its windows moves its key window to each of them in turn, and the accessibility
/// channel reports every step faithfully (#5974's shape, measured at 29ms apart). Each step is a true
/// statement, and the run as a whole is one z-order change in which the user went nowhere: the app puts keys
/// back where they started at the end. Committing each answer scrambled the MRU.
///
/// The last answer is right for both cases — a raise ends where it started, a genuine switch ends on the new
/// window — so waiting for the run to go quiet is the whole rule, and nothing has to be guessed in advance
/// and taken back. This is that rule as a pure function of arrivals; `AttentionEngine` owns the timer that
/// asks it.
///
/// **Per process, never global.** Two apps answering at once are two independent facts (`AttentionModelSpecs`
/// — a fact about an app is not a bid for the front), so one app's burst must not delay another's answer.
struct AttentionSettlePolicy {
    /// Genuine input keeps the measured 60ms burst collapse. With no recent key or mouse event, a longer
    /// settle covers the 150ms programmatic raise sequence from A-11 without taxing user navigation.
    static let userSettle: TimeInterval = 0.06
    static let programmaticSettle: TimeInterval = 0.2
    static let recentInputHorizon: TimeInterval = 0.5

    static func settle(recentInputAge: TimeInterval) -> TimeInterval {
        recentInputAge <= recentInputHorizon ? userSettle : programmaticSettle
    }

    struct Pending: Equatable {
        let wid: CGWindowID
        /// the arrival that armed the current deadline — what a firing timer identifies itself by
        let armedAt: TimeInterval
    }

    private(set) var pending = [pid_t: Pending]()

    /// An answer arrived. It supersedes whatever this process had pending — including its deadline, which is
    /// what makes a run of answers collapse rather than commit the first one `settle` after it started.
    /// Returns when the caller should ask `fire`.
    mutating func offer(pid: pid_t, wid: CGWindowID, now: TimeInterval,
                        settle: TimeInterval = Self.userSettle) -> (deadline: TimeInterval, armedAt: TimeInterval) {
        pending[pid] = Pending(wid: wid, armedAt: now)
        return (now + settle, now)
    }

    /// A deadline fired. `armedAt` NAMES the arrival that armed it: a timer from a superseded answer must
    /// commit nothing, or a burst commits once per member after all. Returns the window to commit, or nil.
    mutating func fire(pid: pid_t, armedAt: TimeInterval) -> CGWindowID? {
        guard let entry = pending[pid], entry.armedAt == armedAt else { return nil }
        pending[pid] = nil
        return entry.wid
    }

    /// A process died. Its pending answer names a window that no longer exists, and a reused pid must not
    /// inherit it.
    mutating func forget(pid: pid_t) {
        pending[pid] = nil
    }
}
