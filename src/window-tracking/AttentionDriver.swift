import Foundation
import CoreGraphics

/// What the click channel saw. Only `clickActivation` has ever been observed firing — see `AttentionSubtype`,
/// where 18 (`clickReactivation`) and 19 (`commandBacktick`) are decoded and dead. They stay named because
/// the decoder still distinguishes them and a future OS may start emitting them.
enum DirectedAttentionKind: Equatable {
    case clickActivation
    case clickReactivation
    case commandBacktick
}

/// **Drives `AttentionModel` from the reducer's input stream.** It holds the model's state and allocates
/// arrival sequences; every decision itself belongs to the pure kernel.
///
/// Its real job is translation, and the translation IS the architecture. The reducer's vocabulary is shaped
/// by where an event came from (the WindowServer, accessibility, our own switch). The model's is shaped by
/// what the evidence MEANS: an activation names an app and nothing else, an app's answer is a fact about
/// that app rather than a bid for the global front, and the WindowServer's order and focus family maps to
/// nothing at all. There is no physical input to attention, which is why the mapping below has a long list
/// of cases that return an empty array.
struct AttentionDriver {
    /// Resolves the facts the model needs but a reducer input does not carry. Closures because the live
    /// answers come from `Applications`/`TabGroups`, and tests supply their own.
    struct Context {
        let generation: (pid_t) -> ProcessGeneration?
        let pidOf: (CGWindowID) -> pid_t?
        /// the wid that stands for this window in the switcher — itself, or its tab group's representative
        let representativeOf: (CGWindowID) -> CGWindowID?
        /// the app that is frontmost RIGHT NOW, from the model rather than from observed transitions
        let frontmostPid: () -> pid_t?
    }

    /// What the model decided, and the window it decided about before the tab mapping was applied.
    struct Outcome: Equatable {
        /// the window to put in front, or nil when nothing should move
        var wid: CGWindowID?
        /// why, for telemetry: `front`, `recorded`, `needsRead`, `none`, or `ignored.<reason>`
        var reason = "noInput"
        /// the window the provider NAMED, before the tab mapping — see `ReducerInput.attentionCommitted`
        var observedWid: CGWindowID?
    }

    private(set) var attention = AttentionModelState()
    private var attentionSequence: UInt64 = 0
    /// When the model asked for a bounded `kAXFocusedWindow` read. The answer is generated at the activation
    /// and lands after whatever the app said in the meantime, so it has to carry the sequence it was ISSUED
    /// at — that is the one place per-process monotonicity has teeth.
    private var readIssuedAt = [ProcessGeneration: IngressSequence]()

    /// One reducer dispatch, decided.
    mutating func decide(_ input: ReducerInput, context: Context) -> Outcome {
        let result = reduceAttention(translate(input, context))
        return Outcome(wid: result.wid, reason: result.reason, observedWid: Self.namedWindow(in: input))
    }

    /// A click naming its target. The strongest evidence in the system and the earliest: it lands before the
    /// app has reacted, and it is right even when the app never reacts at all. In practice this is always the
    /// cross-app click — see `AttentionSubtype`, where 18 and 19 are decoded but never observed.
    mutating func decideDirected(_ kind: DirectedAttentionKind, pid: pid_t, wid: CGWindowID,
                                 context: Context) -> Outcome {
        guard let process = register(pid, context), let identity = identity(wid, process, context) else {
            return Outcome(wid: nil, reason: "unknownProcess", observedWid: wid)
        }
        let result = reduceAttention([.named(.click, observed: identity.observed,
            representative: identity.representative, nextAttention())])
        return Outcome(wid: result.wid, reason: result.reason, observedWid: wid)
    }

    /// An answer arriving from the AX provider rather than as a reducer input. Same sequence space, so a late
    /// answer is measured against the directed evidence that may have overtaken it.
    mutating func decideSemantic(pid: pid_t, wid: CGWindowID, context: Context) -> Outcome {
        syncFrontmost(context)
        let read = ReducerInput.axFocusedWindowRead(wid: wid, viaActivationBackstop: false)
        let result = reduceAttention(translate(read, context))
        return Outcome(wid: result.wid, reason: result.reason, observedWid: wid)
    }

    mutating func processExited(_ generation: ProcessGeneration) {
        readIssuedAt[generation] = nil
        _ = AttentionModel.reduce(&attention, .processExited(generation))
    }

    /// The window an input NAMED, where it names one. A tab switch arrives as an app naming one of its
    /// background tabs, and that wid is the whole signal — see `ReducerInput.attentionCommitted`.
    private static func namedWindow(in input: ReducerInput) -> CGWindowID? {
        switch input {
        case let .axFocusedWindowRead(wid, _): return wid
        case let .altTabFocusedWindowInFrontmostApp(wid, _, _): return wid
        case let .appActivated(_, _, altTabTargetWid): return altTabTargetWid
        default: return nil
        }
    }

    /// Which input produced a decision, for telemetry. `ws808`/`ws815` are named because they are exactly the
    /// two the architecture refuses as attention, so seeing them here at all is a finding.
    static func reason(for input: ReducerInput) -> String {
        switch input {
        case .windowFocused: return "ws808"
        case .windowOrderedIn: return "ws815"
        case .windowOrderedOut: return "ws816"
        case .windowCreated: return "wsCreate"
        case .windowDestroyed: return "wsDestroy"
        case .windowMovedOrResized: return "wsGeometry"
        case .appActivated: return "activation"
        case .spaceMembershipChanged, .spaceTransitionStarted, .spaceChangeSettled: return "space"
        case .discoveryLanded: return "discovery"
        case .titleAndTabsRead: return "titleAndTabs"
        case .windowServerStateRead: return "wsStateRead"
        case .spacesSynced: return "spacesSynced"
        case .axFocusedWindowRead(_, let viaActivationBackstop):
            return viaActivationBackstop ? "axActivationBackstop" : "axFocusedRead"
        case .altTabFocusedWindowInFrontmostApp: return "altTab"
        case .axFocusedWindowReadFailed: return "axReadFailed"
        case .livenessConfirmedDead: return "livenessDead"
        case .cgsWindowListsRead: return "phantomScan"
        case .zOrderRead: return "zOrderSeed"
        case .attentionCommitted: return "attentionCommitted"
        case .holdReleaseCheck: return "holdRelease"
        case .dragOutCheck: return "dragOut"
        }
    }

    /// The reducer's vocabulary, expressed in the model's.
    private mutating func translate(_ input: ReducerInput, _ context: Context) -> [AttentionModelInput] {
        switch input {
        case let .appActivated(pid, _, altTabTargetWid):
            guard let process = register(pid, context) else { return [] }
            var inputs: [AttentionModelInput] = [.frontProcessChanged(process)]
            if let wid = altTabTargetWid, let identity = identity(wid, process, context) {
                inputs.append(.named(.altTab, observed: identity.observed,
                    representative: identity.representative, nextAttention()))
            }
            return inputs
        case let .altTabFocusedWindowInFrontmostApp(wid, pid, _):
            guard let process = register(pid, context),
                  let identity = identity(wid, process, context) else { return [] }
            return [.named(.altTab, observed: identity.observed, representative: identity.representative,
                nextAttention())]
        case let .axFocusedWindowRead(wid, viaActivationBackstop):
            syncFrontmost(context)
            guard let pid = context.pidOf(wid), let process = register(pid, context),
                  let identity = identity(wid, process, context) else { return [] }
            let issued = viaActivationBackstop ? readIssuedAt.removeValue(forKey: process) : nil
            return [.named(viaActivationBackstop ? .activationRead : .app, observed: identity.observed,
                representative: identity.representative, issued ?? nextAttention())]
        case let .axFocusedWindowReadFailed(pid):
            guard let process = register(pid, context) else { return [] }
            // The read this process was waiting on will never answer. Drop its issue sequence, or the next
            // one would carry a sequence older than its own arrival and lose to nothing at all.
            readIssuedAt[process] = nil
            return [.focusedWindowUnknown(process)]
        case .windowFocused, .windowOrderedIn, .windowOrderedOut, .windowCreated, .windowDestroyed,
             .windowMovedOrResized, .zOrderRead, .spaceMembershipChanged,
             .spaceTransitionStarted, .spaceChangeSettled, .discoveryLanded, .titleAndTabsRead,
             .windowServerStateRead, .spacesSynced, .livenessConfirmedDead, .cgsWindowListsRead,
             .holdReleaseCheck, .dragOutCheck,
             // Our own commit coming back through the bridge. Offering it again would decide against our own
             // output.
             .attentionCommitted:
            return []
        }
    }

    /// Reduces and reports: the last window the model put in front, or why it put none there. A
    /// `readFocusedWindow` decision is where the bounded read fires, so its issue sequence is remembered here
    /// for the answer to carry back.
    private mutating func reduceAttention(_ inputs: [AttentionModelInput]) -> (wid: CGWindowID?, reason: String) {
        var decisions = [AttentionModelDecision]()
        for input in inputs {
            let decision = AttentionModel.reduce(&attention, input)
            if case let .readFocusedWindow(process) = decision { readIssuedAt[process] = nextAttention() }
            decisions.append(decision)
        }
        let front = decisions.compactMap { decision -> WindowIdentity? in
            guard case let .front(target) = decision else { return nil }
            return target
        }.last
        return (front?.wid, front == nil ? describe(decisions) : "front")
    }

    private func describe(_ decisions: [AttentionModelDecision]) -> String {
        guard let last = decisions.last else { return "noInput" }
        switch last {
        case .front: return "front"
        case .recorded: return "recorded"
        case .readFocusedWindow: return "needsRead"
        case .none: return "none"
        case let .ignored(reason): return "ignored.\(reason.telemetryName)"
        }
    }

    private mutating func nextAttention() -> IngressSequence {
        attentionSequence += 1
        return IngressSequence(rawValue: attentionSequence)
    }

    /// **Seed the model's idea of the front app from the world, not only from transitions it happened to
    /// witness.** It learns "frontmost" from activations, and an app that was already frontmost when AltTab
    /// started produced none — so every answer that app gave was about a process the model did not think was
    /// in front, and Cmd+` inside it moved nothing (S-06).
    private mutating func syncFrontmost(_ context: Context) {
        guard let pid = context.frontmostPid(), let process = context.generation(pid) else { return }
        guard attention.frontProcess != process else { return }
        _ = AttentionModel.reduce(&attention, .processStarted(process))
        _ = reduceAttention([.frontProcessChanged(process)])
    }

    /// A pid the model has not seen — or has seen under an older generation — is registered before its event
    /// is offered, so it does not answer `staleGeneration` for every app that was already running when AltTab
    /// started.
    private mutating func register(_ pid: pid_t, _ context: Context) -> ProcessGeneration? {
        guard let process = context.generation(pid) else { return nil }
        _ = AttentionModel.reduce(&attention, .processStarted(process))
        return process
    }

    private func identity(_ wid: CGWindowID, _ process: ProcessGeneration,
                          _ context: Context) -> (observed: WindowIdentity, representative: WindowIdentity?)? {
        let observed = WindowIdentity(process: process, wid: wid)
        guard let representativeWid = context.representativeOf(wid) else { return (observed, nil) }
        return (observed, WindowIdentity(process: process, wid: representativeWid))
    }
}

extension AttentionIgnoreReason {
    var telemetryName: String {
        switch self {
        case .staleGeneration: return "staleGeneration"
        case .staleSequence: return "staleSequence"
        case .ineligible: return "ineligible"
        }
    }
}
