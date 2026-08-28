import Foundation

/// The canonical, test-constructible data record of an `Application`. Plain value type, no OS handles
/// — held as a stored `var state: ApplicationState` on the live `Application` class (mutated in place
/// when KVO / AX notifications fire), and constructed directly in tests. The switcher's logic kernels
/// take `ApplicationState` instead of `Application`, so they're hostless / AppKit-free.
struct ApplicationState: Equatable {
    var pid: pid_t
    var bundleIdentifier: String?
    var localizedName: String?
    var isHidden: Bool
}

enum ApplicationAdmissionEvidence: Equatable {
    case discovery
    case attention
}

enum ApplicationAdmissionResolver {
    static func accepts(isXpc: Bool, isZombie: Bool, isKnownUserFacingException: Bool,
                        evidence: ApplicationAdmissionEvidence) -> Bool {
        guard !isZombie else { return false }
        return !isXpc || isKnownUserFacingException || evidence == .attention
    }
}

/// Only `.regular` apps get a placeholder row. An accessory app with no window is a menubar agent, and
/// having been frontmost doesn't make it one the user can switch back to: Raycast's palette and
/// CoreServicesUIAgent's Gatekeeper alert both activate their process, then leave a process whose only
/// surfaces are auxiliary. Pinned by `testAccessoryApplicationNeverGetsPlaceholder`.
enum WindowlessApplicationResolver {
    static func shouldCreate(isRegular: Bool, isTerminated: Bool, hasExistingPlaceholder: Bool,
                             hasNonPhantomWindow: Bool) -> Bool {
        guard !isTerminated, !hasExistingPlaceholder, !hasNonPhantomWindow else { return false }
        return isRegular
    }
}
