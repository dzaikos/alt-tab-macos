import Foundation
import CoreGraphics

/// **Which of an app's answers actually commits.**
///
/// An app raising all its windows moves its key window to each of them in turn, and the accessibility
/// channel reports every step faithfully (#5974's shape, measured at 29ms apart). Each step is a true
/// statement, and the run as a whole is one z-order change in which the user went nowhere: the app puts keys
/// back where they started at the end. Committing each answer scrambled the MRU (QA A-10).
///
/// The last answer is right for both cases — a raise ends where it started, a genuine switch ends on the new
/// window — so waiting for the run to go quiet is the whole rule, and nothing has to be guessed in advance
/// and taken back. This is that rule as a pure function of arrivals; `AttentionEngine` owns the timer that
/// asks it.
///
/// **Per process, never global.** Two apps answering at once are two independent facts (`AttentionModelSpecs`
/// — a fact about an app is not a bid for the front), so one app's burst must not delay another's answer.
struct AttentionSettlePolicy {
    /// A little over the 29ms an app raising its windows was measured at, so a whole run collapses to its
    /// final answer. **Widening it is not free**: it delays every genuine switch by the same amount, against
    /// a measured floor of 219ms for the fastest human action ever captured. Raises spaced wider than this
    /// settle separately and #5974's shape returns — QA A-11 watches that limit in amber rather than
    /// asserting it away, because the fix for it is a different signal, not a bigger number.
    static let settle: TimeInterval = 0.06

    struct Pending: Equatable {
        let wid: CGWindowID
        /// the arrival that armed the current deadline — what a firing timer identifies itself by
        let armedAt: TimeInterval
    }

    private(set) var pending = [pid_t: Pending]()

    /// An answer arrived. It supersedes whatever this process had pending — including its deadline, which is
    /// what makes a run of answers collapse rather than commit the first one `settle` after it started.
    /// Returns when the caller should ask `fire`.
    mutating func offer(pid: pid_t, wid: CGWindowID, now: TimeInterval) -> (deadline: TimeInterval, armedAt: TimeInterval) {
        pending[pid] = Pending(wid: wid, armedAt: now)
        return (now + Self.settle, now)
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
