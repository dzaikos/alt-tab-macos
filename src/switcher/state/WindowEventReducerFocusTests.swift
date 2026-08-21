import XCTest

/// Pins where MRU slot 0 goes when the window holding it is removed
/// (`WindowEventReducer.refrontAfterRemovingTheFocusedWindow`). The captured #5346 sequence is replayed
/// through `TestReducerRunner` because the bug is a sequence, not a single decision; the rule-level
/// scenarios drive `WindowEventReducer.reduce` directly. See WindowEventReducerFocusSpecs.md.
final class WindowEventReducerFocusTests: XCTestCase {

    private static let reaperPid: pid_t = 15690
    private static let finderPid: pid_t = 681
    private static let reaperMainWid: CGWindowID = 4274   // "Country Dance - REAPER v7.78"
    private static let reaperDialogWid: CGWindowID = 4557 // "Insert Multiple Media Items"
    private static let finderWid: CGWindowID = 664        // "Liebesleid"

    private func window(_ wid: CGWindowID, _ pid: pid_t, _ title: String, order: Int,
                        isMinimized: Bool = false) -> TrackedWindow {
        TrackedWindow(id: "wid-\(wid)", wid: wid, pid: pid, title: title,
            size: CGSize(width: 800, height: 600), position: CGPoint(x: 10, y: 10),
            spaceIds: [4], spaceIndexes: [1], isOnAllSpaces: false, spaceIsBorrowed: false,
            isFullscreen: false, isFullscreenMirrored: false, isMinimized: isMinimized, isMainWindow: false,
            isWindowlessApp: false, cgsPhantomLatch: false, lastFocusOrder: order,
            creationOrder: Int(wid), hasThumbnail: true)
    }

    /// Finder frontmost with its window in front, REAPER's main window behind it — the state the capture
    /// starts from (the reporter had just alt-tabbed to Finder to drag the audio files).
    private func state(_ windows: [TrackedWindow], frontmost: pid_t) -> TrackedWindowState {
        var s = TrackedWindowState()
        s.windows = windows
        s.apps[Self.reaperPid] = TrackedApp(state: ApplicationState(pid: Self.reaperPid,
            bundleIdentifier: "com.cockos.reaper", localizedName: "REAPER", isHidden: false),
            isActive: frontmost == Self.reaperPid)
        s.apps[Self.finderPid] = TrackedApp(state: ApplicationState(pid: Self.finderPid,
            bundleIdentifier: "com.apple.finder", localizedName: "Finder", isHidden: false),
            isActive: frontmost == Self.finderPid)
        s.frontmostPid = frontmost
        s.visibleSpaces = [4]
        s.currentSpaceId = 4
        s.spaceIndexById = [4: 1]
        return s
    }

    private func order(_ state: TrackedWindowState, _ wid: CGWindowID) -> Int? {
        state.window(wid)?.lastFocusOrder
    }

    // MARK: - A. The captured #5346 sequence

    /// The reporter's transcribed capture: a dialog opened by a drag (REAPER still in the background) is
    /// discovered and fronted, the click that dismisses it activates REAPER — so the main window's own 808
    /// is swallowed as the activation's raise tail — and then the dialog is removed. Slot 0 must not fall
    /// through to Finder, or every alt-tab lands back on the REAPER window the user is already in.
    func testDialogClosingLeavesTheFrontmostAppInFront() {
        let runner = TestReducerRunner(initial: state([
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.finderPid))
        runner.run(capturedDialogSteps(withActivation: true))
        XCTAssertEqual(order(runner.state, Self.reaperMainWid), 0)
        XCTAssertEqual(order(runner.state, Self.finderWid), 1)
    }

    /// The same sequence minus the activation: the main window's 808 is then an ordinary focus and bumps on
    /// its own, so the removal has nothing to repair. Isolates the activation as the trigger.
    func testTheSameSequenceWithoutTheActivationNeedsNoRepair() {
        let runner = TestReducerRunner(initial: state([
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.finderPid))
        runner.run(capturedDialogSteps(withActivation: false))
        XCTAssertEqual(order(runner.state, Self.reaperMainWid), 0)
        XCTAssertEqual(order(runner.state, Self.finderWid), 1)
    }

    /// The capture, input by input (timestamps are the log's own, in seconds since its first event).
    private func capturedDialogSteps(withActivation: Bool) -> [TestReducerRunner.Step] {
        var steps: [TestReducerRunner.Step] = [
            // 13:28:13.588-.845 — the dialog appears while REAPER is in the background: created at 0×0,
            // sized a beat later, focused before it is tracked, then discovered.
            .input(.windowCreated(wid: Self.reaperDialogWid, now: 13.588, inSpaceTransition: false)),
            .input(.windowMovedOrResized(wid: Self.reaperDialogWid, inSpaceTransition: false)),
            .input(.windowOrderedIn(wid: Self.reaperDialogWid, now: 13.622, inSpaceTransition: false)),
            .input(.windowFocused(wid: Self.reaperDialogWid, now: 13.634)),
            .track(window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0)),
            .input(.discoveryLanded(wid: Self.reaperDialogWid, accepted: true, newlyTracked: true,
                adoptedAsInactiveTab: false, queriedSpaceIds: [4], isOrderedIn: true, tabTitles: nil)),
            // 13:28:14.96 — the click on the dialog's button brings REAPER to the front.
            .setAppActive(pid: Self.finderPid, isActive: false),
            .setAppActive(pid: Self.reaperPid, isActive: true),
            .setFrontmost(pid: Self.reaperPid),
        ]
        if withActivation {
            steps.append(.input(.appActivated(pid: Self.reaperPid, now: 14.960, altTabTargetWid: nil)))
        }
        steps += [
            // 13:28:14.961-.962 — the two 808s, 1 ms apart: the dialog, then the main window.
            .input(.windowFocused(wid: Self.reaperDialogWid, now: 14.961)),
            .input(.windowOrderedIn(wid: Self.reaperDialogWid, now: 14.962, inSpaceTransition: false)),
            .input(.windowFocused(wid: Self.reaperMainWid, now: 14.962)),
            .input(.windowOrderedIn(wid: Self.reaperMainWid, now: 14.962, inSpaceTransition: false)),
            // 13:28:16.92-.96 — the dialog goes off-screen and the AX probe confirms it closed.
            .input(.windowOrderedOut(wid: Self.reaperDialogWid, inSpaceTransition: false)),
            .input(.livenessConfirmedDead(wid: Self.reaperDialogWid)),
        ]
        return steps
    }

    // MARK: - C. Restoring a minimized window (QA I-11, #5439's shape)

    private static let textEditPid: pid_t = 95772
    private static let teRestoredWid: CGWindowID = 90112 // the minimized window the user picked
    private static let teSiblingWid: CGWindowID = 90106  // the one they never touched

    private func restoreState() -> TrackedWindowState {
        var s = TrackedWindowState()
        s.windows = [
            window(Self.finderWid, Self.finderPid, "lwouis", order: 0),
            window(Self.teRestoredWid, Self.textEditPid, "Untitled", order: 1, isMinimized: true),
            window(Self.teSiblingWid, Self.textEditPid, "Untitled 2", order: 2),
        ]
        s.apps[Self.textEditPid] = TrackedApp(state: ApplicationState(pid: Self.textEditPid,
            bundleIdentifier: "com.apple.TextEdit", localizedName: "TextEdit", isHidden: false),
            isActive: false)
        s.apps[Self.finderPid] = TrackedApp(state: ApplicationState(pid: Self.finderPid,
            bundleIdentifier: "com.apple.finder", localizedName: "Finder", isHidden: false), isActive: true)
        s.frontmostPid = Self.finderPid
        s.visibleSpaces = [4]
        s.currentSpaceId = 4
        s.spaceIndexById = [4: 1]
        return s
    }

    /// The QA I-11 capture (2026-07-31). AltTab focuses a MINIMIZED window, so it deminiaturizes first —
    /// and unlike every other AltTab focus, that stirs the app's other windows. macOS answered with a focus
    /// 808 for the SIBLING 38ms into the activation; with an AltTab activation's empty snapshot that was not
    /// a raise, so it took slot 0 off the window the user had just restored (#5439's shape).
    ///
    /// This pins the reducer end of the fix: `ActivationFocusResolver.onActivation` only knows to keep the
    /// snapshot because `appActivated` tells it the target was minimized, and the kernel tests cannot prove
    /// that call site passes it.
    func testRestoringAMinimizedWindowKeepsItInFrontOfItsSibling() {
        let runner = TestReducerRunner(initial: restoreState())
        runner.run([
            .setAppActive(pid: Self.finderPid, isActive: false),
            .setAppActive(pid: Self.textEditPid, isActive: true),
            .setFrontmost(pid: Self.textEditPid),
            // 02:04:04.833 — our own focus, so the target is known and bumped directly.
            .input(.appActivated(pid: Self.textEditPid, now: 4.833, altTabTargetWid: Self.teRestoredWid)),
            // 02:04:04.871 — the deminiaturize tail: the sibling, which the user never asked for.
            .input(.windowFocused(wid: Self.teSiblingWid, now: 4.871)),
            .input(.windowOrderedIn(wid: Self.teSiblingWid, now: 4.871, inSpaceTransition: false)),
            // 02:04:04.874 — the window actually being restored arrives 3ms later.
            .input(.windowOrderedIn(wid: Self.teRestoredWid, now: 4.874, inSpaceTransition: false)),
        ])
        // The restored window takes slot 0 and everything else keeps its relative order: Finder shifts down
        // to 1, and the sibling — whose focus was swallowed as the tail — does not move at all.
        XCTAssertEqual(order(runner.state, Self.teRestoredWid), 0)
        XCTAssertEqual(order(runner.state, Self.finderWid), 1)
        XCTAssertEqual(order(runner.state, Self.teSiblingWid), 2)
    }

    /// The same tail against a NON-minimized target must still bump: that is #5785's second alt-tab, where
    /// muting the sibling's genuine 808 left every following alt-tab on the window the user was already in.
    /// The two live behaviours differ only by whether AltTab had to deminiaturize.
    func testFocusingANonMinimizedWindowStillLetsTheSiblingsFocusBump() {
        var initial = restoreState()
        initial.windows[1].isMinimized = false
        let runner = TestReducerRunner(initial: initial)
        runner.run([
            .setAppActive(pid: Self.finderPid, isActive: false),
            .setAppActive(pid: Self.textEditPid, isActive: true),
            .setFrontmost(pid: Self.textEditPid),
            .input(.appActivated(pid: Self.textEditPid, now: 4.833, altTabTargetWid: Self.teRestoredWid)),
            .input(.windowFocused(wid: Self.teSiblingWid, now: 4.871)),
        ])
        XCTAssertEqual(order(runner.state, Self.teSiblingWid), 0)
    }

    // MARK: - B. The rule

    /// Another app holds slot 1, but focus never crosses apps because a window closed: the frontmost app's
    /// own next window takes the front, and `.applyFocus` names it so the live model agrees.
    func testRemovingTheFocusedWindowPromotesTheFrontmostAppsNextWindow() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 2),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperDialogWid))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// An ordinary close of a background window leaves slot 0 alone — nothing to repair, nothing bumped.
    func testRemovingANonFrontWindowPromotesNothing() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperDialogWid))
        XCTAssertFalse(effects.contains { if case .applyFocus = $0 { return true } else { return false } })
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// The frontmost app's last window closes: there is nothing of its own left to promote, so the global
    /// shift stands (the app is on its way to windowless).
    func testRemovingTheFrontmostAppsOnlyWindowPromotesNothing() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperMainWid))
        XCTAssertFalse(effects.contains { if case .applyFocus = $0 { return true } else { return false } })
    }

    /// A minimized window is off screen and never received the focus the closing window gave up.
    func testMinimizedWindowsAreNotPromoted() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1,
                isMinimized: true),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 2),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperDialogWid))
        XCTAssertFalse(effects.contains(.applyFocus(Self.reaperMainWid)))
    }

    /// An inactive tab is off screen too — what the user sees is its group's representative.
    func testInactiveTabsAreNotPromoted() {
        let backgroundTab: CGWindowID = 4600
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(backgroundTab, Self.reaperPid, "background tab", order: 1),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 2),
        ], frontmost: Self.reaperPid)
        s.formGroup([Self.reaperMainWid, backgroundTab], representative: Self.reaperMainWid, reason: "test")
        XCTAssertTrue(s.isTabbed(s.window(backgroundTab)!), "precondition: an inactive tab")
        let effects = WindowEventReducer.reduce(&s, .windowDestroyed(wid: Self.reaperDialogWid))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertFalse(effects.contains(.applyFocus(backgroundTab)))
    }

    // MARK: - D. The screen coming back (#5936)

    /// The measured burst: waking the display orders EVERY window back in inside one millisecond, with no
    /// order-out in front of it, so `offScreen` cannot tell the re-show from a raise. Each order-in of the
    /// active app's windows would otherwise re-front, walking that app's whole set to the top of the MRU in
    /// burst order — "all my Chrome windows are at the front", after only stepping away.
    func testTheWakeBurstDoesNotReorderTheMru() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 2),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .systemReshow(now: 100, source: .wake))
        // the burst, 2.03s after the wake notification (measured), every window in the same millisecond
        for wid in [Self.reaperDialogWid, Self.finderWid, Self.reaperMainWid] {
            let effects = WindowEventReducer.reduce(&s,
                .windowOrderedIn(wid: wid, now: 102.03, inSpaceTransition: false))
            XCTAssertFalse(effects.contains(.applyFocus(wid)), "#\(wid) was re-fronted by the wake burst")
        }
        XCTAssertEqual(order(s, Self.reaperDialogWid), 0)
        XCTAssertEqual(order(s, Self.finderWid), 1)
        XCTAssertEqual(order(s, Self.reaperMainWid), 2)
    }

    /// The capture that showed the damage in full (21:39:01, macOS 26): opening Mission Control emits the
    /// same burst 12ms after the Dock's `AXExposeShowAllWindows`, and the frontmost app's three windows —
    /// sitting at MRU 0, 2 and 3 — were all re-fronted, in burst order. Nothing else was in flight: no Space
    /// transition, no activation, no lock, no sleep. Just Mission Control.
    func testTheMissionControlBurstDoesNotReorderTheMru() {
        let reaperThirdWid: CGWindowID = 4601
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
            window(reaperThirdWid, Self.reaperPid, "Untitled", order: 3),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .systemReshow(now: 100, source: .missionControl))
        for wid in [Self.reaperMainWid, Self.finderWid, Self.reaperDialogWid, reaperThirdWid] {
            let effects = WindowEventReducer.reduce(&s,
                .windowOrderedIn(wid: wid, now: 100.012, inSpaceTransition: false))
            XCTAssertFalse(effects.contains(.applyFocus(wid)), "#\(wid) was re-fronted by Mission Control")
        }
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
        XCTAssertEqual(order(s, Self.finderWid), 1)
        XCTAssertEqual(order(s, Self.reaperDialogWid), 2)
        XCTAssertEqual(order(s, reaperThirdWid), 3)
    }

    /// The backstop, with NO signal armed at all: the same burst is recognised by its shape, because a raise
    /// moves one window and a re-show moves all of them at once. The first member still bumps (nothing
    /// separates it from a raise yet) and is harmless — it is the frontmost app's front window, already at
    /// MRU 0. Members 2..N are the damage, and they are what this catches.
    func testABurstIsCaughtByItsShapeWithNoSignalArmed() {
        let reaperThirdWid: CGWindowID = 4601
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
            window(reaperThirdWid, Self.reaperPid, "Untitled", order: 3),
        ], frontmost: Self.reaperPid)
        // the captured spacing: consecutive members ~0.12ms apart
        for (i, wid) in [Self.reaperMainWid, Self.finderWid, Self.reaperDialogWid, reaperThirdWid].enumerated() {
            _ = WindowEventReducer.reduce(&s,
                .windowOrderedIn(wid: wid, now: 100 + Double(i) * 0.00012, inSpaceTransition: false))
        }
        XCTAssertEqual(order(s, Self.reaperMainWid), 0, "the burst's first member held the front it already had")
        XCTAssertEqual(order(s, Self.finderWid), 1)
        XCTAssertEqual(order(s, Self.reaperDialogWid), 2, "a burst member walked to the front")
        XCTAssertEqual(order(s, reaperThirdWid), 3, "a burst member walked to the front")
    }

    /// The counterfactual that keeps Cmd+` working: an order-in ARRIVING ALONE is still the in-app raise it
    /// has always been. 200ms is under the fastest human action in any capture (219ms, #5785).
    func testALoneOrderInStillBumps() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperDialogWid, now: 100, inSpaceTransition: false))
        let effects = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperMainWid, now: 100.2, inSpaceTransition: false))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// The SAME window ordered in twice in an instant is not a burst, it is one window reported twice — the
    /// shape every genuine focus has (its 808 and its 815 land in the same millisecond).
    func testTheSameWindowTwiceIsNotABurst() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperMainWid, now: 100, inSpaceTransition: false))
        let effects = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperMainWid, now: 100.001, inSpaceTransition: false))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// An UNTRACKED wid in the burst still counts as evidence: a re-show sweeps up every window on screen,
    /// including ones we have not discovered yet, and a record with holes cannot recognise a burst. Here the
    /// untracked wid separates two tracked ones, so without it the second would read as arriving alone.
    func testAnUntrackedWidCountsAsBurstEvidence() {
        let untrackedWid: CGWindowID = 9999
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 0),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowOrderedIn(wid: untrackedWid, now: 100, inSpaceTransition: false))
        let effects = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperDialogWid, now: 100.001, inSpaceTransition: false))
        XCTAssertFalse(effects.contains(.applyFocus(Self.reaperDialogWid)))
        XCTAssertEqual(order(s, Self.reaperDialogWid), 1)
    }

    /// Each mute is sized for its own trigger, and this is what that buys: dismiss Mission Control, cycle
    /// windows a beat later, and the raise still moves the MRU. Under one mute sized for the wake burst's
    /// 2.03s lag, a Cmd+` a second after a gesture that finishes in 100ms was swallowed.
    func testAnInAppRaiseASecondAfterMissionControlStillBumps() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .systemReshow(now: 100, source: .missionControl))
        let effects = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperMainWid, now: 101, inSpaceTransition: false))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// ...and the wake mute really does stay open that long, because its own burst arrives at 2.03s. The two
    /// together are the whole point of sizing per source rather than taking the slowest for everyone.
    func testTheWakeMuteStillCoversItsOwnLateBurst() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .systemReshow(now: 100, source: .wake))
        let effects = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperMainWid, now: 102.03, inSpaceTransition: false))
        XCTAssertFalse(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 1)
    }

    /// The mute is time-bounded, because the signal it stands in front of is real: an order-in of the active
    /// app's window IS the native Cmd+` raise, which emits nothing else. Past the window it bumps as before.
    func testAnInAppRaiseStillBumpsOnceTheMuteExpired() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .systemReshow(now: 100, source: .wake))
        let effects = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperMainWid, now: 103.5, inSpaceTransition: false))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// Only the order-in path is muted. An 808 is the OS STATING a focus rather than us inferring one from a
    /// raise, the wake burst contains none, and swallowing one would lose the first window the user picks.
    func testAFocusEventDuringTheMuteStillBumps() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .systemReshow(now: 100, source: .wake))
        let effects = WindowEventReducer.reduce(&s,
            .windowFocused(wid: Self.reaperMainWid, now: 102.03))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// An un-minimize is spared the mute: a wake leaves minimized windows minimized, so a window our model
    /// watched leave that state was restored by the user. It matters because a Dock restore inside the
    /// already-frontmost app emits ONLY this order-in — nothing behind it would correct a swallowed bump.
    func testRestoringAMinimizedWindowDuringTheMuteStillBumps() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "Country Dance - REAPER v7.78", order: 1,
                isMinimized: true),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .systemReshow(now: 100, source: .wake))
        let effects = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperMainWid, now: 102.03, inSpaceTransition: false))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
        XCTAssertEqual(s.window(Self.reaperMainWid)?.isMinimized, false)
    }

    // MARK: - E. An app raising ALL its windows while already frontmost (#5974)

    /// The captured Chrome wids and their MRU slots, so the replay below reads as the capture does.
    private static let c1: CGWindowID = 51228   // held the front, before and after
    private static let c2: CGWindowID = 51241
    private static let c3: CGWindowID = 51249   // the burst's first member, from MRU 4
    private static let finder2Wid: CGWindowID = 665

    /// `BEFORE  C1(0)  other(1)  C2(2)  other(3)  C3(4)` — the interleaved MRU the capture starts from, with
    /// the bursting app owning slots 0, 2 and 4. Reaper stands in for Chrome, Finder for the two apps
    /// between its windows.
    private func interleavedState() -> TrackedWindowState {
        state([
            window(Self.c1, Self.reaperPid, "C1", order: 0),
            window(Self.finderWid, Self.finderPid, "System Settings", order: 1),
            window(Self.c2, Self.reaperPid, "C2", order: 2),
            window(Self.finder2Wid, Self.finderPid, "Claude", order: 3),
            window(Self.c3, Self.reaperPid, "C3", order: 4),
        ], frontmost: Self.reaperPid)
    }

    /// The measured burst, verbatim (18:26:01, macOS 26.6): one 808 plus one 815 per window, 29ms between
    /// windows, no `didActivateApplication` anywhere. Every 808 fell through to "bump iff the app is active"
    /// and the app's whole set walked to the top, pushing every other app under it.
    private func raiseAllSteps(_ s: inout TrackedWindowState) {
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.c3, now: 100.417))
        _ = WindowEventReducer.reduce(&s, .windowOrderedIn(wid: Self.c3, now: 100.417, inSpaceTransition: false))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.c2, now: 100.446))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.c1, now: 100.446))
        _ = WindowEventReducer.reduce(&s, .windowOrderedIn(wid: Self.c1, now: 100.446, inSpaceTransition: false))
    }

    /// The report. The app itself still says C1 has keys — nobody moved — so the whole run resolves to zero
    /// net bumps and the interleaved order the user built is exactly as they left it. No bump-based rule can
    /// reach this verdict; it comes from asking the app, which is the point of the burst.
    func testAnAppRaisingAllItsWindowsLeavesTheMruAlone() {
        var s = interleavedState()
        raiseAllSteps(&s)
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100.417, focusedWid: Self.c1))
        XCTAssertEqual(order(s, Self.c1), 0, "the window that had keys all along lost the front")
        XCTAssertEqual(order(s, Self.finderWid), 1, "another app was pushed under the raised set")
        XCTAssertEqual(order(s, Self.c2), 2)
        XCTAssertEqual(order(s, Self.finder2Wid), 3, "another app was pushed under the raised set")
        XCTAssertEqual(order(s, Self.c3), 4, "the burst's first member kept a front it never earned")
    }

    /// The same run, resolved to a DIFFERENT member: that one window fronts and nothing else of the app's
    /// moves. Stamped at the run's FIRST 808, not at the moment the read landed, so anything the OS focused
    /// while the read was in flight still outranks it (`noteFocus` refuses older news).
    func testTheBurstResolvedToAMemberFrontsThatOneAlone() {
        var s = interleavedState()
        raiseAllSteps(&s)
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100.417, focusedWid: Self.c2))
        XCTAssertEqual(order(s, Self.c2), 0)
        XCTAssertEqual(order(s, Self.c1), 1)
        XCTAssertEqual(order(s, Self.finderWid), 2)
        XCTAssertEqual(order(s, Self.finder2Wid), 3)
        XCTAssertEqual(order(s, Self.c3), 4, "the speculative bump of the first member was not rolled back")
        XCTAssertEqual(s.window(Self.c2)?.focusedAt, 100.417, "the verdict was stamped at the run's first 808, not at the moment the read landed")
    }

    /// A two-window run resolving to the window that already held the front: the first member's speculative
    /// bump — made before a second 808 could reveal the run — is undone.
    func testATwoWindowBurstResolvedToTheFrontRollsTheSpeculativeBumpBack() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        XCTAssertEqual(order(s, Self.reaperDialogWid), 0, "a lone 808 must still bump synchronously")
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100, focusedWid: Self.reaperMainWid))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
        XCTAssertEqual(order(s, Self.finderWid), 1)
        XCTAssertEqual(order(s, Self.reaperDialogWid), 2)
    }

    /// ...and the other verdict on the same run: the app confirms the first member really did take keys, so
    /// its bump stands untouched. Both answers have to be reachable, or the read is decoration.
    func testATwoWindowBurstResolvedToTheFirstMemberKeepsItsBump() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100, focusedWid: Self.reaperDialogWid))
        XCTAssertEqual(order(s, Self.reaperDialogWid), 0)
        XCTAssertEqual(order(s, Self.reaperMainWid), 1)
    }

    /// A lone 808 keeps the synchronous fast path it has always had: it bumps on the spot and asks the app
    /// nothing. That is the overwhelming majority of this stream, and it must cost no latency and no AX call.
    func testALoneFocusEventBumpsWithoutAskingTheApp() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 1),
        ], frontmost: Self.reaperPid)
        let effects = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertFalse(effects.contains(.resolveFocusAfterBurst(pid: Self.reaperPid, runStartedAt: 100)),
            "a lone 808 must not spend an AX read")
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// The same window focused twice in an instant is one window reported twice, not a run of different
    /// windows — `Window.focus()` fires several calls for one wid. Mirrors the 815 path's own rule.
    func testTheSameWindowFocusedTwiceIsNotABurst() {
        var s = state([
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100))
        let effects = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.001))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// **AltTab's own switch, landing inside somebody else's storm.** Focusing a window of the app that is
    /// already frontmost raises no app, so no activation follows and `altTabIntentToRecord` deliberately
    /// keeps nothing (#5596) — the switch rides on this single 808. Held back with the rest of the run it
    /// would be lost for good, since re-focusing an already-focused window emits nothing at all. Resolved
    /// with a FAILED read on purpose: the bump must not depend on the oracle answering.
    func testAltTabsOwnFocusInsideABurstStillBumps() {
        let reaperThirdWid: CGWindowID = 4601
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
            window(reaperThirdWid, Self.reaperPid, "Untitled", order: 3),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: reaperThirdWid, now: 100))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        _ = WindowEventReducer.reduce(&s, .altTabFocusedWindowInFrontmostApp(
            wid: Self.reaperDialogWid, pid: Self.reaperPid, now: 100.05))
        let effects = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100.06))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperDialogWid)),
            "the user's own switch was swallowed as a burst member")
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100, focusedWid: nil))
        XCTAssertEqual(order(s, Self.reaperDialogWid), 0)
    }

    /// `kAXFocusedWindow` is answered at all times, whether or not anything just happened to the app, so a
    /// read naming a window the run never touched is stale news and decides nothing.
    func testAStaleReadNamingAnOutsiderChangesNothing() {
        var s = interleavedState()
        raiseAllSteps(&s)
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100.417, focusedWid: Self.finderWid))
        XCTAssertEqual(order(s, Self.c3), 0, "a stale read moved the MRU")
        XCTAssertEqual(order(s, Self.finderWid), 2, "a stale read fronted a window of another app")
    }

    /// A read that failed outright (an app that is gone, busy, or hiding its AX tree) leaves the run's
    /// speculative bump standing — today's behaviour — rather than guessing in the oracle's place.
    func testAnUnresolvedBurstLeavesTheSpeculativeBumpStanding() {
        var s = interleavedState()
        raiseAllSteps(&s)
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100.417, focusedWid: nil))
        XCTAssertEqual(order(s, Self.c3), 0)
    }

    /// The ORDER-INS are held with the 808s: the capture pairs each raise with an 815 in the same
    /// millisecond, and the 815 path's own `reshowBurstGap` (5ms, sized for a WindowServer re-show at
    /// ~0.12ms between members) cannot see an app raising its own windows 29ms apart. Without this the
    /// suppressed 808s would simply be re-fronted by their own order-ins.
    func testOrderInsAreHeldWhileAFocusBurstIsInFlight() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        let effects = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperMainWid, now: 100.04, inSpaceTransition: false))
        XCTAssertFalse(effects.contains(.applyFocus(Self.reaperMainWid)),
            "an order-in re-fronted a window whose own 808 was held")
        XCTAssertTrue(effects.contains(.resolveFocusAfterBurst(pid: Self.reaperPid, runStartedAt: 100)),
            "the order-in must re-arm the read, not let it fire mid-run")
        XCTAssertEqual(order(s, Self.reaperMainWid), 1)
    }

    /// An UNTRACKED member is the one window we know least about, so promoting it on arrival while the run's
    /// tracked windows are all held back would hand it MRU 0 for no reason. It joins the run instead; if the
    /// app names it, `focusBurstResolved` arms the promotion then.
    func testAnUntrackedFocusInsideABurstIsNotPromoted() {
        let untrackedWid: CGWindowID = 9999
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        let effects = WindowEventReducer.reduce(&s, .windowFocused(wid: untrackedWid, now: 100.05))
        XCTAssertTrue(effects.contains(.discoverWindow(wid: untrackedWid, throttled: false)))
        XCTAssertNil(s.pendingFocusPromotion[untrackedWid],
            "an untracked burst member was armed to front itself on discovery")
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100, focusedWid: untrackedWid))
        XCTAssertEqual(s.pendingFocusPromotion[untrackedWid],
            .circumstantial(at: 100, frontmostPid: Self.reaperPid),
            "the app named it, so the withheld promotion must be armed now — time-placed at the run")
    }

    /// An untracked 808 with NO run in flight keeps its promotion: a freshly-focused window whose 808 outran
    /// its async discovery would otherwise land at the back of the MRU (#5785).
    func testAnUntrackedFocusOutsideABurstIsStillPromoted() {
        let untrackedWid: CGWindowID = 9999
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: untrackedWid, now: 100))
        XCTAssertEqual(s.pendingFocusPromotion[untrackedWid], .asserted)
    }

    /// Two 808s for the same app a beat apart are two separate focuses, not a run: 300ms is past
    /// `focusBurstGap` and past the fastest human action ever captured (219ms, #5785).
    func testTwoFocusesABeatApartAreNotABurst() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        let effects = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.3))
        XCTAssertTrue(effects.contains(.applyFocus(Self.reaperMainWid)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }

    /// **A LATE answer must not close a later run.** The read is asynchronous, and `AXCallScheduler` holds a
    /// second call for the same key until the first returns, so run 1's answer can arrive after run 2 opened
    /// — routine for a busy app, and guaranteed once the scheduler backs off. Closing run 2 there would drop
    /// the focus events it is holding, with nothing behind them to correct the order (#5596 / #5875).
    func testALateAnswerDoesNotCloseTheNextRun() {
        let reaperThirdWid: CGWindowID = 4601
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
            window(reaperThirdWid, Self.reaperPid, "Untitled", order: 3),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: reaperThirdWid, now: 100.03))
        // run 2 opens well past the gap, so run 1's read is already in flight
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.5))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100.53))
        // run 1's answer, landing 430ms late
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100,
            focusedWid: reaperThirdWid))
        // ...and now run 2's own answer, which must still find its run
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100.5,
            focusedWid: Self.reaperDialogWid))
        XCTAssertEqual(order(s, Self.reaperDialogWid), 0,
            "run 2's verdict found no record: the late answer for run 1 had already closed it")
    }

    /// A window can join a run through the ORDER-IN path alone — the native Cmd+` raise emits an 815 and no
    /// 808 at all. Holding its bump and then rejecting the verdict that names it as "no member of the run"
    /// would swallow the raise twice over, and re-raising an already-raised window emits nothing to fix it.
    func testAnOrderInOnlyRaiseInsideABurstIsStillResolvable() {
        let reaperThirdWid: CGWindowID = 4601
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
            window(reaperThirdWid, Self.reaperPid, "Untitled", order: 3),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        // the user's Cmd+` lands inside the run: an order-in, for a window with no 808 of its own
        _ = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: reaperThirdWid, now: 100.05, inSpaceTransition: false))
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100,
            focusedWid: reaperThirdWid))
        XCTAssertEqual(order(s, reaperThirdWid), 0,
            "the verdict naming the raised window was rejected as a stale read")
    }

    /// The hold covers the untracked ORDER-IN too, not just the untracked 808. A circumstantial promotion
    /// fronts the window the moment discovery lands, which is the one outcome the hold exists to prevent —
    /// so an undiscovered window of the bursting app would keep the #5974 scramble alive on its own.
    func testAnUntrackedOrderInInsideABurstIsNotPromoted() {
        let untrackedWid: CGWindowID = 9999
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        _ = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: untrackedWid, now: 100.05, inSpaceTransition: false))
        XCTAssertNil(s.pendingFocusPromotion[untrackedWid],
            "an untracked window ordered in by the run was armed to front itself on discovery")
    }

    /// A move/resize reaches the untracked tail carrying no `now` at all, so the run test must not be applied
    /// to it — a zero timestamp reads as "inside every run that ever started".
    func testAnUntrackedMoveIsNotMistakenForABurstMember() {
        let untrackedWid: CGWindowID = 9999
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 1),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        _ = WindowEventReducer.reduce(&s,
            .windowMovedOrResized(wid: untrackedWid, inSpaceTransition: false))
        XCTAssertNotNil(s.pendingFocusPromotion[untrackedWid],
            "a move was read as a burst member and lost its promotion")
    }

    /// The rollback restores the window BEHIND the one it sat behind, not an absolute rank, because ranks
    /// shift under a run: a genuine focus landing mid-run moves everything behind it down one, and a saved
    /// position of 4 then puts the window back a slot too far forward.
    func testTheRollbackSurvivesAGenuineFocusLandingMidRun() {
        var s = interleavedState()
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.c3, now: 100.417))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.c2, now: 100.446))
        // the user clicks the other app mid-run, on the window that sat BEHIND c3
        _ = WindowEventReducer.reduce(&s, .appActivated(pid: Self.finderPid, now: 100.5, altTabTargetWid: nil))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.finder2Wid, now: 100.51))
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100.417,
            focusedWid: Self.c1))
        XCTAssertEqual(order(s, Self.finder2Wid), 0, "the window the user actually clicked lost the front")
        XCTAssertEqual(order(s, Self.c1), 1)
        XCTAssertEqual(order(s, Self.finderWid), 2)
        XCTAssertEqual(order(s, Self.c2), 3)
        XCTAssertEqual(order(s, Self.c3), 4, "the rolled-back window came back a slot too far forward")
    }

    /// **The first member's own ORDER-IN re-stamps it, microseconds after its 808.** Every genuine focus
    /// has that pair, and the two arrival times differ in the microseconds — so a rollback guard demanding
    /// `focusedAt` still equal the instant the run STARTED never matches in the field, and the speculative
    /// bump stands whatever the app answers. Live capture 17:10:15.629 (QA A-10), where both events print
    /// the same millisecond and the rollback silently did not fire. The unit tests missed it by passing the
    /// same literal `now` to both.
    func testTheFirstMembersOwnOrderInDoesNotDefeatTheRollback() {
        var s = state([
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 0),
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
        ], frontmost: Self.reaperPid)
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100))
        _ = WindowEventReducer.reduce(&s,
            .windowOrderedIn(wid: Self.reaperDialogWid, now: 100.000_2, inSpaceTransition: false))
        _ = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.03))
        _ = WindowEventReducer.reduce(&s, .focusBurstResolved(pid: Self.reaperPid, runStartedAt: 100,
            focusedWid: Self.reaperMainWid))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0,
            "the run's speculative bump was not rolled back: its own order-in had re-stamped focusedAt")
        XCTAssertEqual(order(s, Self.finderWid), 1)
        XCTAssertEqual(order(s, Self.reaperDialogWid), 2)
    }

    /// Inside a live activation nothing here applies: that storm is the OS's own, `ActivationFocusResolver`
    /// rules it alone (first 808 = the focus, the raise tail swallowed), and the run must not double-judge it.
    func testAnActivationStormIsStillTheActivationResolversAlone() {
        var s = state([
            window(Self.finderWid, Self.finderPid, "Liebesleid", order: 0),
            window(Self.reaperMainWid, Self.reaperPid, "REAPER", order: 1),
            window(Self.reaperDialogWid, Self.reaperPid, "Insert Multiple Media Items", order: 2),
        ], frontmost: Self.finderPid)
        _ = WindowEventReducer.reduce(&s, .appActivated(pid: Self.reaperPid, now: 100, altTabTargetWid: nil))
        let first = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperMainWid, now: 100.01))
        XCTAssertTrue(first.contains(.applyFocus(Self.reaperMainWid)), "the activation's first 808 is the focus")
        XCTAssertFalse(first.contains(.resolveFocusAfterBurst(pid: Self.reaperPid, runStartedAt: 100)))
        let tail = WindowEventReducer.reduce(&s, .windowFocused(wid: Self.reaperDialogWid, now: 100.04))
        XCTAssertFalse(tail.contains(.applyFocus(Self.reaperDialogWid)), "the raise tail must stay swallowed")
        XCTAssertFalse(tail.contains(.resolveFocusAfterBurst(pid: Self.reaperPid, runStartedAt: 100)))
        XCTAssertEqual(order(s, Self.reaperMainWid), 0)
    }
}
