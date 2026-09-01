import XCTest

/// Pins the per-process settle that collapses an app's burst of accessibility answers to its last one.
/// See AttentionSettlePolicySpecs.md.
final class AttentionSettlePolicyTests: XCTestCase {
    private let chrome: pid_t = 500
    private let finder: pid_t = 600

    /// **#5974, verbatim.** Chrome raises its four windows 29ms apart while already frontmost, answering
    /// once per window, and ends on the window it started on. One commit, naming the last answer.
    func testARunOfAnswersCommitsOnceWithTheLastWindow() {
        var policy = AttentionSettlePolicy()
        var commits = [CGWindowID]()
        var armed: TimeInterval = 0
        for (i, wid) in [CGWindowID(1), 2, 3, 1].enumerated() {
            let now = Double(i) * 0.029
            // the previous deadline fires only if it was not superseded; at 29ms apart none of them is due
            armed = policy.offer(pid: chrome, wid: wid, now: now).armedAt
        }
        if let wid = policy.fire(pid: chrome, armedAt: armed) { commits.append(wid) }
        XCTAssertEqual(commits, [1], "the run committed more than its final answer")
    }

    /// The teeth: a timer armed by an answer that was overtaken must commit nothing. Without the `armedAt`
    /// check every member of the run commits when its own timer fires, which is the bug the settle exists
    /// to prevent.
    func testASupersededTimerCommitsNothing() {
        var policy = AttentionSettlePolicy()
        let first = policy.offer(pid: chrome, wid: 1, now: 0)
        _ = policy.offer(pid: chrome, wid: 2, now: 0.029)
        XCTAssertNil(policy.fire(pid: chrome, armedAt: first.armedAt),
                     "a superseded answer committed; the burst commits once per member")
    }

    /// The deadline follows the LAST answer. Anchored to the first, a run would commit 60ms after it began —
    /// mid-burst, on a window the user never landed on.
    func testTheDeadlineIsPushedBackByEachAnswer() {
        var policy = AttentionSettlePolicy()
        XCTAssertEqual(policy.offer(pid: chrome, wid: 1, now: 0).deadline,
                       AttentionSettlePolicy.userSettle, accuracy: 0.0001)
        XCTAssertEqual(policy.offer(pid: chrome, wid: 2, now: 0.029).deadline,
                       0.029 + AttentionSettlePolicy.userSettle, accuracy: 0.0001)
    }

    /// One answer with nothing behind it is not a burst: it commits, unchanged.
    func testAQuietAnswerCommitsItself() {
        var policy = AttentionSettlePolicy()
        let armed = policy.offer(pid: chrome, wid: 7, now: 10).armedAt
        XCTAssertEqual(policy.fire(pid: chrome, armedAt: armed), 7)
        XCTAssertNil(policy.fire(pid: chrome, armedAt: armed), "the answer committed twice")
    }

    /// Two apps holding different facts is the normal state, not a conflict — so a talkative app must not
    /// hold up a quiet one's answer.
    func testTwoAppsSettleIndependently() {
        var policy = AttentionSettlePolicy()
        let finderArmed = policy.offer(pid: finder, wid: 100, now: 0).armedAt
        _ = policy.offer(pid: chrome, wid: 1, now: 0.01)
        _ = policy.offer(pid: chrome, wid: 2, now: 0.02)
        XCTAssertEqual(policy.fire(pid: finder, armedAt: finderArmed), 100,
                       "one app's burst swallowed another app's answer")
    }

    /// A pending answer names a window of a process that has gone. A reused pid must not inherit it.
    func testAProcessExitDropsItsPendingAnswer() {
        var policy = AttentionSettlePolicy()
        let armed = policy.offer(pid: chrome, wid: 1, now: 0).armedAt
        policy.forget(pid: chrome)
        XCTAssertNil(policy.fire(pid: chrome, armedAt: armed))
    }

    func testRecentInputSelectsTheShortSettle() {
        XCTAssertEqual(AttentionSettlePolicy.settle(recentInputAge: 0.1),
                       AttentionSettlePolicy.userSettle)
        XCTAssertEqual(AttentionSettlePolicy.settle(recentInputAge: 1.0),
                       AttentionSettlePolicy.programmaticSettle)
    }

    func testAProgrammaticRunSpaced150msApartCommitsOnce() {
        var policy = AttentionSettlePolicy()
        var armed: TimeInterval = 0
        for (i, wid) in [CGWindowID(1), 2, 3, 1].enumerated() {
            let now = Double(i) * 0.15
            armed = policy.offer(pid: chrome, wid: wid, now: now,
                                 settle: AttentionSettlePolicy.programmaticSettle).armedAt
        }
        XCTAssertEqual(policy.fire(pid: chrome, armedAt: armed), 1)
    }
}
