import Cocoa

/// WindowServer-owned facts about one painted surface. A surface is not necessarily something the switcher
/// should offer: sheets, children, panels and menus are surfaces too.
struct PhysicalSurface: Equatable {
    let wid: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let level: CGWindowLevel
    let parentWid: CGWindowID
    let isVisible: Bool
    let isMinimized: Bool
    let isFullscreen: Bool
    let alpha: Float

    init(wid: CGWindowID, pid: pid_t, bounds: CGRect, level: CGWindowLevel, parentWid: CGWindowID = 0,
         isVisible: Bool = true, isMinimized: Bool = false, isFullscreen: Bool = false, alpha: Float = 1) {
        self.wid = wid
        self.pid = pid
        self.bounds = bounds
        self.level = level
        self.parentWid = parentWid
        self.isVisible = isVisible
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.alpha = alpha
    }

    init(_ raw: WsRawWindow) {
        self.init(wid: raw.wid, pid: raw.pid, bounds: raw.bounds,
            level: CGWindowLevel(raw.level), parentWid: raw.parentWid,
            isVisible: WsWindowState.isVisible(raw), isMinimized: WsWindowState.isMinimized(raw),
            isFullscreen: WsWindowState.isFullscreen(raw), alpha: raw.alpha)
    }

    var isSubstantial: Bool {
        bounds.width >= WindowAdmissionResolver.minimumWidth &&
            bounds.height >= WindowAdmissionResolver.minimumHeight
    }
}

/// Accessibility-owned meaning for a physical surface. Nil fields are evidence too: broken/custom toolkits
/// often expose a real AXWindow root while omitting the conventional subrole.
struct SemanticSurface: Equatable {
    let title: String?
    let subrole: String?
    let role: String?
    let isMain: Bool?

    var hasTitle: Bool { !(title ?? "").isEmpty }
    var isWindowRole: Bool { role == kAXWindowRole }
}

enum WindowAdmissionEvidence: Equatable {
    case discovery
    case attention
}

enum WindowAdmissionReason: String, Equatable {
    case invalidWindowId
    case attachedSurface
    case exactAttention
    case awaitingAccessibility
    case conventionalWindow
    case mainWindow
    case customWindowRoot
    case auxiliarySurface
    case untitledDialog
    case undersizedCustomSurface
    case nonWindowRole
    case unsupportedSemantics
}

/// The user-facing result is deliberately richer than a Boolean. A painted surface may itself be a switch
/// destination, represent another destination, need more evidence, or be known not to be one.
enum SwitchDestinationDecision: Equatable {
    case destination(WindowAdmissionReason)
    case represent(parentWid: CGWindowID, WindowAdmissionReason)
    case latent(WindowAdmissionReason)
    case reject(WindowAdmissionReason)

    var reason: WindowAdmissionReason {
        switch self {
        case let .destination(reason), let .represent(_, reason), let .latent(reason), let .reject(reason):
            return reason
        }
    }

    var isDestination: Bool {
        if case .destination = self { return true }
        return false
    }
}

/// Resolves physical, semantic and behavioral evidence into a switch destination. Rules are ordered by
/// authority rather than scored: exact relationships beat behavioral evidence, which beats conventions,
/// which beat coarse size/level priors.
enum WindowAdmissionResolver {
    static let minimumWidth: CGFloat = 100
    static let minimumHeight: CGFloat = 50
    static let normalLevel: CGWindowLevel = 0

    /// Whether ordinary discovery should pay the AX acquisition cost. Level zero is a cheap positive hint,
    /// never a rejection: a substantial non-zero-level surface is inspected too, and exact attention bypasses
    /// this optimization entirely.
    static func shouldAcquireSemantics(_ physical: PhysicalSurface) -> Bool {
        physical.wid != 0 && physical.parentWid == 0 &&
            (physical.level == normalLevel || physical.isSubstantial)
    }

    static func resolve(_ physical: PhysicalSurface, _ semantic: SemanticSurface?,
                        evidence: WindowAdmissionEvidence = .discovery) -> SwitchDestinationDecision {
        guard physical.wid != 0 else { return .reject(.invalidWindowId) }
        guard physical.parentWid == 0 else { return .represent(parentWid: physical.parentWid, .attachedSurface) }
        if let semantic, isAuxiliary(semantic.subrole) { return .reject(.auxiliarySurface) }
        if evidence == .attention { return .destination(.exactAttention) }
        guard let semantic else { return .latent(.awaitingAccessibility) }
        if semantic.isWindowRole && semantic.isMain == true { return .destination(.mainWindow) }
        if semantic.subrole == kAXStandardWindowSubrole { return .destination(.conventionalWindow) }
        if semantic.subrole == kAXDialogSubrole {
            return semantic.hasTitle ? .destination(.conventionalWindow) : .latent(.untitledDialog)
        }
        if semantic.isWindowRole && semantic.hasTitle && physical.isSubstantial {
            if semantic.isMain != true && physical.level != normalLevel { return .reject(.auxiliarySurface) }
            return .destination(.customWindowRoot)
        }
        guard semantic.isWindowRole else { return .reject(.nonWindowRole) }
        guard physical.isSubstantial else { return .latent(.undersizedCustomSurface) }
        return .latent(.unsupportedSemantics)
    }

    private static func isAuxiliary(_ subrole: String?) -> Bool {
        subrole == kAXFloatingWindowSubrole || subrole == "AXSystemDialog"
    }
}
