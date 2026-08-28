import Foundation

/// The canonical, test-constructible data record of a `Window`. One type, used by every kernel that
/// operates on window facts (`WindowFilterResolver`, `WindowOrderResolver`, `ExceptionMatcher`) —
/// replaces the per-feature mirror structs. Held as a stored `var state: WindowState` on the live
/// `Window` class (mutated in place when window data changes) and constructed directly in tests.
///
/// **No nested `ApplicationState`**: kernels that also need application facts take it as a separate
/// parameter alongside the window state. This avoids two mutable copies of the same app data going
/// out of sync (one on `Application`, one nested inside each `WindowState`).
///
/// `spaceIds` / `spaceIndexes` use the underlying primitive types (`UInt64` / `Int`) rather than the
/// app-only `CGSSpaceID` / `SpaceIndex` typealiases, so this file compiles in the unit-tests target
/// without dragging in `Spaces` / SkyLight.
struct WindowState: Equatable {
    var id: String
    var isPhantom: Bool
    var isWindowlessApp: Bool
    var isFullscreen: Bool
    var isMinimized: Bool
    var isTabbed: Bool
    /// A tab kept visible through the new-tab discovery gap (`Windows.windowsHeldVisibleForTab`). Like
    /// `isPhantom`/`isTabbed` it is DERIVED (patched into `state` by the live `Window`), never stored raw.
    /// The switcher's Space/screen filters read it: a held tab just backgrounded on the CURRENT visible
    /// Space, so it is Space-less (its 1326 landed) yet must still draw one tile — see `WindowFilterResolver`.
    var isHeldVisibleForTab = false
    var isOnAllSpaces: Bool
    var spaceIds: [UInt64]          // CGSSpaceID === UInt64
    var spaceIndexes: [Int]         // SpaceIndex === Int
    var lastFocusOrder: Int
    var creationOrder: Int
    var title: String
    // cached AXMain (is this the app's main window). Read off-main with the other window attributes so
    // `Windows.findMainWindow` reads a flag instead of doing AX IPC in a sort comparator on the show path.
    var isMainWindow = false
    /// How much AltTab actually KNOWS about this window, as opposed to what the WindowServer says exists.
    /// Defaults to `.axVerified` because every window that comes through the ordinary discovery path was
    /// discriminated against real AX attributes before it was constructed.
    var axStatus = AxSemanticStatus.axVerified
}

/// **What backs a tracked window, and therefore how much the switcher may claim about it.**
///
/// The WindowServer owns which windows exist. Accessibility owns what they are called and what role they
/// play. Those two used to be one step: a WindowServer row only became a tracked window if an AX element
/// could be resolved for it first, so a window whose app was hung simply never entered the list — and that is
/// exactly the window a click can name, by wid, before the app has reacted to anything.
///
/// Splitting them means the physical window can be retained while its semantics are missing or stale. What
/// changes with the status is PRESENTATION, not existence: a candidate is tracked, ordered and correctable,
/// but is not offered to the user until something vouches for it.
enum AxSemanticStatus: Equatable {
    /// the WindowServer lists it and it passed the physical checks; AX has not spoken for it yet
    case wsCandidate
    /// AX resolved a live window element and discrimination accepted it — the ordinary case
    case axVerified
    /// AX resolved it and discrimination said it is not a switchable window. Permanent for this wid.
    case axRejected
    /// AX could not answer at all: the app is hung, quarantined, or has not come up yet. **Never permanent**
    /// — a temporary failure that latched as a rejection is how a window disappears and never comes back.
    case axUnavailable
    /// a candidate the user demonstrably went to (a click named its wid, or AltTab focused it), so it is
    /// shown on that evidence alone rather than waiting for an app that may never answer
    case directedCandidate

    /// Whether the switcher may offer this window. Deliberately conservative: only a verified window, or one
    /// the user has been directed to, is drawn.
    var isPresentable: Bool {
        self == .axVerified || self == .directedCandidate
    }
}
