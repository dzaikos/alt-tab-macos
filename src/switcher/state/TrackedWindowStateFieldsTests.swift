import XCTest

/// The guard on the one bug class the replay harness is structurally blind to.
///
/// `TrackedWindowStateBridge.snapshot()` builds a FRESH `TrackedWindowState()` for every dispatch, so a field
/// it does not repopulate is empty at the start of every input — anything written by one event and read by
/// the next silently never fires. `TestReducerRunner` threads ONE state through a whole scenario and never
/// round-trips it through the bridge, so every replay test stays green while the feature does nothing in the
/// app. Eight fields shipped that way (`offScreen` plus the whole minted-tab handover chain) with 817 tests
/// passing; it took a live capture to notice, twice.
///
/// So every stored property of `TrackedWindowState` must be CLASSIFIED here, and the class it is put in is a
/// claim about how it survives between dispatches:
///
///   - `carried` — the one field with no live-model home. Its own properties are parked wholesale by the
///     bridge, so anything nested inside it is safe by construction. New reducer memory belongs in there.
///   - `projections` — rebuilt from the live model on every snapshot (`Windows.list`, `TabGroups.table`,
///     the `Spaces` topology…). Safe because the model, not the struct, is the source of truth.
///   - `perDispatch` — deliberately fresh each input. Only `now`, which is stamped by the shell.
///
/// Adding a field to `TrackedWindowState` without deciding which of the three it is fails this test. That is
/// the entire point: the decision is cheap, and getting it wrong by DEFAULT is what cost the live iterations.
final class TrackedWindowStateFieldsTests: XCTestCase {

    /// Rebuilt from the live model by `snapshot()`. If you add one here, add the matching line to BOTH
    /// `snapshot()` and `apply()` — a projection is only as good as the two sides that copy it.
    private static let projections: Set<String> = [
        "windows", "apps", "groups", "held", "recentlyCreated", "pendingSpaceRemoval", "pendingFocusPromotion",
        "visibleSpaces", "currentSpaceId", "spaceIndexById", "frontmostPid",
    ]

    /// Stamped fresh per dispatch, on purpose.
    private static let perDispatch: Set<String> = ["now"]

    func testEveryStateFieldIsClassifiedAsCarriedProjectedOrPerDispatch() {
        let fields = Mirror(reflecting: TrackedWindowState()).children.compactMap { $0.label }
        XCTAssertFalse(fields.isEmpty, "reflection found no stored properties — the check would pass vacuously")
        let classified = Self.projections.union(Self.perDispatch).union(["carried"])
        let unclassified = fields.filter { !classified.contains($0) }
        XCTAssertEqual(unclassified, [], """
            \(unclassified) is stored on TrackedWindowState but not classified. Decide how it survives \
            between dispatches: move it into `TrackedWindowState.Carried` (parked by the bridge — the right \
            answer for anything one event writes and another reads), or list it in `projections` here AND \
            copy it in both `TrackedWindowStateBridge.snapshot()` and `apply()`. Leaving it unclassified \
            means it is silently reset before every input.
            """)
    }

    /// Every stored property of `TrackedWindow`, the per-window half of the same trap. `snapshot()` builds
    /// each one from the live `Window` and `apply()` writes it back, so a field missing from EITHER side is
    /// inert in the app while every replay test stays green (the harness threads one state and never crosses
    /// the bridge).
    ///
    /// **This is an ADD-ONLY tripwire, and that is all it is.** Reflection sees the property, not the two
    /// bridge lines, so DELETING either one still passes here — verified by mutation. What it buys is the
    /// moment that matters in practice: adding a field fails this test, which is where you are told the
    /// bridge exists at all. Pinning the copies themselves needs a behavioural test per field, and the ones
    /// for `isOrderedIn` live in `WindowEventReducerMinimizeTests` section E.
    private static let trackedWindowFields: Set<String> = [
        // identity / shell-owned: not written back by `apply()`, see its comment for why
        "id", "wid", "pid", "title", "isWindowlessApp", "creationOrder", "hasThumbnail",
        // reducer-owned: must be in BOTH `modelWindow()` and `apply()`
        "size", "position", "spaceIds", "spaceIndexes", "isOnAllSpaces", "spaceIsBorrowed",
        "isFullscreen", "isFullscreenMirrored", "isMinimized", "isMainWindow", "cgsPhantomLatch",
        "isOrderedIn", "alpha", "lastLeftSpaceId", "replacedByWid", "replacedWid", "tabCount",
        "tabGroupObservation", "spaceMembershipObservation", "focusedAt", "lastFocusOrder", "lifecycle",
    ]

    func testEveryTrackedWindowFieldIsAccountedForByTheBridge() {
        let fields = Set(Mirror(reflecting: TrackedWindow(id: "wid-1", pid: 1)).children.compactMap { $0.label })
        XCTAssertFalse(fields.isEmpty, "reflection found no stored properties — the check would pass vacuously")
        XCTAssertEqual(fields.subtracting(Self.trackedWindowFields), [], """
            new TrackedWindow field(s). Copy them in BOTH `TrackedWindowStateBridge.modelWindow()` and \
            `apply()`, then list them here — a field missing from either side reads as its default on every \
            dispatch, and no replay test can see it.
            """)
        XCTAssertEqual(Self.trackedWindowFields.subtracting(fields), [], "listed here but no longer stored")
    }

    /// The classification's other half: a name listed here that no longer exists is a stale claim, and would
    /// quietly excuse a future field that happens to reuse the name.
    func testNoClassifiedFieldHasBeenRemovedOrRenamed() {
        let fields = Set(Mirror(reflecting: TrackedWindowState()).children.compactMap { $0.label })
        let stale = Self.projections.union(Self.perDispatch).subtracting(fields).sorted()
        XCTAssertEqual(stale, [], "classified but no longer stored on TrackedWindowState")
    }

    /// `Carried` is what the bridge parks, so it must actually be round-trippable as a value: `apply` reads
    /// `state.carried` and `snapshot` writes it back verbatim, and any reference type smuggled in there would
    /// alias the two sides instead of copying.
    func testCarriedRoundTripsAsAValue() {
        var carried = TrackedWindowState.Carried()
        carried.offScreen = [1, 2, 3]
        carried.pendingHandoverEdge[7] = .init(partnerWid: 8, pendingSideJoined: true)
        var copy = carried
        copy.offScreen.insert(4)
        copy.pendingHandoverEdge.removeAll()
        XCTAssertEqual(carried.offScreen, [1, 2, 3], "mutating the copy changed the original")
        XCTAssertEqual(carried.pendingHandoverEdge[7]?.partnerWid, 8)
    }
}
