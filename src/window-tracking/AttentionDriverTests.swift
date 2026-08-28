import XCTest
import CoreGraphics

final class AttentionDriverTests: XCTestCase {
    private let pid: pid_t = 10
    private let otherPid: pid_t = 20

    /// Every wid belongs to `pid` and stands for itself, unless a test says otherwise.
    private func context(pidOf: [CGWindowID: pid_t] = [:],
                         representatives: [CGWindowID: CGWindowID] = [:]) -> AttentionDriver.Context {
        AttentionDriver.Context(
            generation: { ProcessGeneration(pid: $0, generation: 1) },
            pidOf: { pidOf[$0] ?? self.pid },
            representativeOf: { representatives[$0] ?? $0 },
            frontmostPid: { nil })
    }

    private func activated(_ driver: inout AttentionDriver, _ pid: pid_t) {
        _ = driver.decide(.appActivated(pid: pid, now: 0, altTabTargetWid: nil), context: context())
    }

    // MARK: what is, and is not, attention

    /// The load-bearing one: an 808 is not a member of the vocabulary at all, so it declines without needing
    /// a rule to decline with. Every WindowServer order and focus event maps to nothing.
    func testPhysicalEventsAreNotAttention() {
        var driver = AttentionDriver()
        activated(&driver, pid)
        for input: ReducerInput in [.windowFocused(wid: 5, now: 1),
                                    .windowOrderedIn(wid: 5, now: 1, inSpaceTransition: false),
                                    .windowOrderedOut(wid: 5, inSpaceTransition: false),
                                    .zOrderRead(widsTopFirst: [5])] {
            let outcome = driver.decide(input, context: context())
            XCTAssertNil(outcome.wid, "\(input) moved the front")
            XCTAssertEqual(outcome.reason, "noInput")
        }
    }

    func testSpaceAndDiscoveryInputsNameNothing() {
        var driver = AttentionDriver()
        let outcome = driver.decide(.spacesSynced(windowToSpaces: [:], queried: [],
            placedByWindowServer: [], topologyChanged: false), context: context())
        XCTAssertEqual(outcome.reason, "noInput")
    }

    // MARK: the two levels

    /// An activation of an app nobody has answered for is where the bounded read fires. R6: it is the one
    /// hole nothing else fills, because a plain activation names no window from any source.
    func testActivationWithNoFactAsksForARead() {
        var driver = AttentionDriver()
        let outcome = driver.decide(.appActivated(pid: pid, now: 0, altTabTargetWid: nil), context: context())
        XCTAssertNil(outcome.wid)
        XCTAssertEqual(outcome.reason, "needsRead")
    }

    /// An app's own answer puts its window in front once that app is the front process.
    func testAnAppAnswerFrontsItsWindow() {
        var driver = AttentionDriver()
        activated(&driver, pid)
        let outcome = driver.decide(.axFocusedWindowRead(wid: 2, viaActivationBackstop: false),
            context: context())
        XCTAssertEqual(outcome.wid, 2)
        XCTAssertEqual(outcome.reason, "front")
    }

    /// R2, every namer writes a fact and never a command: an answer from an app the user is NOT in records
    /// the fact and moves nothing. It is not refused, and it is not thrown away.
    func testAnAnswerFromABackgroundAppIsRecordedAndMovesNothing() {
        var driver = AttentionDriver()
        activated(&driver, pid)
        let outcome = driver.decide(.axFocusedWindowRead(wid: 9, viaActivationBackstop: false),
            context: context(pidOf: [9: otherPid]))
        XCTAssertNil(outcome.wid)
        XCTAssertEqual(outcome.reason, "recorded")
    }

    /// ...and activating that app later lands on the window it named, with no read needed.
    func testTheRecordedFactIsWhatTheNextActivationLandsOn() {
        var driver = AttentionDriver()
        activated(&driver, pid)
        _ = driver.decide(.axFocusedWindowRead(wid: 9, viaActivationBackstop: false),
            context: context(pidOf: [9: otherPid]))
        let outcome = driver.decide(.appActivated(pid: otherPid, now: 1, altTabTargetWid: nil),
            context: context(pidOf: [9: otherPid]))
        XCTAssertEqual(outcome.wid, 9)
        XCTAssertEqual(outcome.reason, "front")
    }

    /// The click names both levels at once, so it fronts a window of an app that has not activated yet. This
    /// is the only source that survives an app too busy to answer.
    func testAClickFrontsItsWindowWithoutWaitingForTheActivation() {
        var driver = AttentionDriver()
        activated(&driver, pid)
        let outcome = driver.decideDirected(.clickActivation, pid: otherPid, wid: 9,
            context: context(pidOf: [9: otherPid]))
        XCTAssertEqual(outcome.wid, 9)
    }

    /// AltTab's own switch names the window it is switching to.
    func testAnActivationCarryingAnAltTabTargetFrontsIt() {
        var driver = AttentionDriver()
        let outcome = driver.decide(.appActivated(pid: pid, now: 0, altTabTargetWid: 4), context: context())
        XCTAssertEqual(outcome.wid, 4)
    }

    /// An app that answers with a background tab names the tile that stands for it, since that is what the
    /// switcher draws.
    func testAnAnswerMapsThroughTheTabRepresentative() {
        var driver = AttentionDriver()
        activated(&driver, pid)
        let outcome = driver.decide(.axFocusedWindowRead(wid: 8, viaActivationBackstop: false),
            context: context(representatives: [8: 3]))
        XCTAssertEqual(outcome.wid, 3)
        XCTAssertEqual(outcome.observedWid, 8, "the tile is what moves; the wid the app named is reported")
    }

    /// R5, unknown is a value: an app that cannot say which of its windows is focused does not get one
    /// guessed for it from stacking order. The bounded read coming back empty is the one input that says so.
    func testAnAppThatCannotAnswerMovesNothing() {
        var driver = AttentionDriver()
        activated(&driver, pid)
        let outcome = driver.decide(.axFocusedWindowReadFailed(pid: pid), context: context())
        XCTAssertNil(outcome.wid)
    }

    // MARK: process generations

    /// An app already running when AltTab started must not answer as a stale generation.
    func testUnseenPidIsRegisteredBeforeItsEvent() {
        var driver = AttentionDriver()
        let outcome = driver.decide(.altTabFocusedWindowInFrontmostApp(wid: 2, pid: pid, now: 0),
            context: context())
        XCTAssertEqual(outcome.wid, 2)
    }

    /// A relaunched pid does not inherit the dead process's facts.
    func testRelaunchedPidDoesNotInheritTheDeadProcessesFact() {
        var driver = AttentionDriver()
        activated(&driver, pid)
        _ = driver.decide(.axFocusedWindowRead(wid: 2, viaActivationBackstop: false), context: context())
        driver.processExited(ProcessGeneration(pid: pid, generation: 1))
        let relaunched = AttentionDriver.Context(
            generation: { ProcessGeneration(pid: $0, generation: 2) },
            pidOf: { _ in self.pid },
            representativeOf: { $0 },
            frontmostPid: { nil })
        let outcome = driver.decide(.appActivated(pid: pid, now: 1, altTabTargetWid: nil),
            context: relaunched)
        XCTAssertEqual(outcome.reason, "needsRead", "the new generation starts with no fact of its own")
    }

    /// R1, per-process monotonicity: the bounded read's answer carries the sequence it was ISSUED at, so an
    /// app that spoke for itself in the meantime keeps the last word.
    func testTheBoundedReadLosesToAnAnswerThatOvertookIt() {
        var driver = AttentionDriver()
        let outcome = driver.decide(.appActivated(pid: pid, now: 0, altTabTargetWid: nil), context: context())
        XCTAssertEqual(outcome.reason, "needsRead")
        _ = driver.decide(.axFocusedWindowRead(wid: 3, viaActivationBackstop: false), context: context())
        let late = driver.decide(.axFocusedWindowRead(wid: 1, viaActivationBackstop: true), context: context())
        XCTAssertEqual(late.reason, "ignored.staleSequence")
        XCTAssertEqual(driver.attention.visibleFront?.wid, 3)
    }

    /// **A read that never answers must not date the next one.** The read fires on every activation, while
    /// the model only asks for one when it has no fact — so an activation that needed no read consumes
    /// whatever issue sequence the last one left behind. If a failed read leaves its sequence in place, the
    /// next answer carries a sequence older than everything the app said meanwhile and is thrown away as
    /// stale, leaving the front on a window the user has left.
    func testAFailedReadDoesNotDateTheNextAnswer() {
        var driver = AttentionDriver()
        XCTAssertEqual(driver.decide(.appActivated(pid: pid, now: 0, altTabTargetWid: nil),
            context: context()).reason, "needsRead")
        _ = driver.decide(.axFocusedWindowReadFailed(pid: pid), context: context())
        _ = driver.decide(.axFocusedWindowRead(wid: 3, viaActivationBackstop: false), context: context())
        XCTAssertEqual(driver.attention.visibleFront?.wid, 3)
        // a second activation: the model has a fact now, so it asks for no read — but one fires anyway
        _ = driver.decide(.appActivated(pid: pid, now: 1, altTabTargetWid: nil), context: context())
        let late = driver.decide(.axFocusedWindowRead(wid: 4, viaActivationBackstop: true), context: context())
        XCTAssertEqual(late.wid, 4, "the failed read's stale sequence swallowed a fresh answer")
    }

    // MARK: reason codes

    /// Every input maps to a reason code, so nothing can be attributed to "focus" in general.
    func testEveryInputHasADistinctReasonCode() {
        let inputs: [ReducerInput] = [
            .windowFocused(wid: 1, now: 0),
            .windowOrderedIn(wid: 1, now: 0, inSpaceTransition: false),
            .appActivated(pid: 1, now: 0, altTabTargetWid: nil),
            .axFocusedWindowRead(wid: 1, viaActivationBackstop: false),
            .axFocusedWindowRead(wid: 1, viaActivationBackstop: true),
            .axFocusedWindowReadFailed(pid: 1),
            .zOrderRead(widsTopFirst: []),
        ]
        let reasons = inputs.map { AttentionDriver.reason(for: $0) }
        XCTAssertEqual(reasons, ["ws808", "ws815", "activation", "axFocusedRead", "axActivationBackstop",
                                 "axReadFailed", "zOrderSeed"])
    }
}
