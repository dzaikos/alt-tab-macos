import Cocoa

/// **The live shell around `AttentionModel`: the one place the running app decides which window the user is
/// looking at.** Main-thread only, like the model it feeds.
///
/// Three channels reach it, and they are the only three:
/// - **the reducer's input stream** (`dispatched`), for an app activation, an answer to the bounded
///   `kAXFocusedWindow` read, and AltTab's own switch into an app already in front;
/// - **the app's own accessibility observer** (`axSemanticFocus`), settled per process;
/// - **the click channel** (`directedAttention`), the type-13 tap in `WindowAttentionEvents`.
///
/// A decision that arrives outside the reducer's input stream is committed back into the model here, as
/// `.attentionCommitted`. Nothing else in the app may move the window order — see `AttentionOrderSpecs.md`.
///
/// Deciding is `AttentionModel`'s, translating is `AttentionDriver`'s; what lives here is the impure part:
/// which process generation a pid currently has, the settle timer, and the commit.
class AttentionEngine {
    private static var driver = AttentionDriver()
    private static var generations = [pid_t: UInt64]()

    /// A dispatch just ran. Returns the window the attention model decided to put in front, for the bridge to
    /// apply inside the same dispatch: deferring it to the next runloop turn would let the switcher draw one
    /// frame with the old order first.
    @discardableResult
    static func dispatched(_ input: ReducerInput) -> (wid: CGWindowID, observed: CGWindowID)? {
        // Our own commit coming back through the bridge. Deciding on it again would decide against our own
        // output.
        if case .attentionCommitted = input { return nil }
        let context = context()
        let outcome = driver.decide(input, context: context)
        guard let target = outcome.wid else { return nil }
        let pid = context.pidOf(target)
        TrackingTelemetryRecorder.attentionCommitted(pid: pid ?? 0, wid: target,
            processGeneration: pid.flatMap { generations[$0] }, source: provider(of: input),
            reason: AttentionDriver.reason(for: input), status: outcome.reason)
        return (target, outcome.observedWid ?? target)
    }

    /// Which channel named the window, for telemetry. The reducer's vocabulary says where an input came from,
    /// and that is exactly what a disagreement has to be attributable to — recording every one of them as
    /// `accessibility` would make an activation and an app's own answer indistinguishable in a capture.
    private static func provider(of input: ReducerInput) -> TrackingProvider {
        switch input {
        case .appActivated: return .workspace
        case .altTabFocusedWindowInFrontmostApp: return .altTab
        default: return .accessibility
        }
    }

    /// Commit an attention decision that did not arrive as a reducer input — a click, or an app answering
    /// through its own AX observer.
    private static func commit(_ wid: CGWindowID?, observed: CGWindowID? = nil) {
        guard let wid else { return }
        TrackedWindowStateBridge.dispatch(.attentionCommitted(wid: wid, observed: observed ?? wid,
            at: ProcessInfo.processInfo.systemUptime))
    }

    // MARK: process identity

    /// A new process generation. A relaunched pid must NOT inherit the previous process's generation, or a
    /// callback from the dead one would look current to every rule keyed on identity.
    static func processStarted(_ pid: pid_t) {
        generations[pid] = (generations[pid] ?? 0) + 1
        TrackingTelemetryRecorder.trackingGenerationChanged()
    }

    static func processExited(_ pid: pid_t) {
        settlePolicy.forget(pid: pid)
        guard let generation = generations[pid] else { return }
        driver.processExited(ProcessGeneration(pid: pid, generation: generation))
        TrackingTelemetryRecorder.processExited(pid)
    }

    /// The generation the tracking pipeline currently associates with this pid. Lazily assigned, so an app
    /// that was already running when AltTab started has an identity too.
    static func generation(of pid: pid_t) -> UInt64 {
        let generation = generations[pid] ?? 1
        generations[pid] = generation
        return generation
    }

    // MARK: the app's own answer

    /// **An app's answers are debounced per process, and only the last one commits.**
    ///
    /// An app raising all its windows really does move its key window to each of them in turn (#5974's
    /// shape, measured at 29ms apart), and the accessibility channel reports every step faithfully. Each step
    /// is a true statement and the run as a whole is one z-order change in which the user went nowhere: the
    /// app puts keys back where they started at the end. Committing each answer scrambled the order (A-10).
    ///
    /// The last answer is the right one for both cases — the raise ends where it started, a genuine switch
    /// ends on the new window — so waiting for the run to stop is enough, and nothing has to be guessed in
    /// advance and taken back. The wait is a little over the measured spacing and is invisible unless the
    /// user summons the switcher inside it.
    ///
    /// A click is NOT debounced: it names its target exactly, and it is the user's own action. Cmd+` reaches
    /// attention only through this same accessibility channel — the tap is silent for it — and is debounced
    /// with everything else the app says.
    static func axSemanticFocus(pid: pid_t, wid: CGWindowID) {
        let armed = settlePolicy.offer(pid: pid, wid: wid, now: ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + AttentionSettlePolicy.settle) {
            guard let target = settlePolicy.fire(pid: pid, armedAt: armed.armedAt) else { return }
            applySemanticFocus(pid: pid, wid: target)
        }
    }

    /// Which answer survives a run is `AttentionSettlePolicy`'s (a pure triad); the timer is this file's.
    private static var settlePolicy = AttentionSettlePolicy()

    private static func applySemanticFocus(pid: pid_t, wid: CGWindowID) {
        let outcome = driver.decideSemantic(pid: pid, wid: wid, context: context())
        // Only a COMMITTED result is attention. Writing the refused ones as attention too would leave
        // `lastAttention` reporting a window the rules had just declined, which is the opposite of what a
        // reader of that field is asking.
        guard let target = outcome.wid else {
            return TrackingTelemetryRecorder.attentionRefused(pid: pid, wid: wid, source: .accessibility,
                reason: outcome.reason)
        }
        TrackingTelemetryRecorder.attentionCommitted(pid: pid, wid: target,
            processGeneration: generations[pid], source: .accessibility, reason: "axObserver",
            status: outcome.reason)
        commit(target, observed: outcome.observedWid)
    }

    // MARK: the click channel

    /// A click naming its target window (subtype 9; the reactivate and Cmd+` subtypes are decoded but have
    /// never been observed firing). It names both the app and the window at once, so it is the one input
    /// that commits immediately, without waiting for the app to speak.
    static func directedAttention(_ kind: DirectedAttentionKind, pid: pid_t, wid: CGWindowID, subtype: Int) {
        TrackingTelemetryRecorder.sessionTapEvent(subtype: subtype, pid: pid, wid: wid, decoded: true)
        // About EXISTENCE, not order: a window the user demonstrably clicked is shown even if its app never
        // answers AX. Without this the click channel names a window the switcher still refuses to draw.
        Windows.promoteDirected(wid)
        representDirectedWindow(wid, pid: pid)
        let outcome = driver.decideDirected(kind, pid: pid, wid: wid, context: context())
        guard let target = outcome.wid else {
            return TrackingTelemetryRecorder.attentionRefused(pid: pid, wid: wid, source: .annotatedSession,
                reason: outcome.reason)
        }
        TrackingTelemetryRecorder.attentionCommitted(pid: pid, wid: target,
            processGeneration: generations[pid], source: .annotatedSession,
            reason: kind == .commandBacktick ? "type13cycle" : "type13click", status: outcome.reason)
        commit(target, observed: outcome.observedWid)
    }

    /// **A click named a window nobody is tracking.** Its app is not answering accessibility — otherwise
    /// discovery would have it — so the WindowServer's own row is all there is, and it is enough: the user is
    /// looking at that window right now.
    private static func representDirectedWindow(_ wid: CGWindowID, pid: pid_t) {
        guard Windows.byWindowId[wid] == nil else { return }
        CGSCallScheduler.run {
            guard let raw = WindowServerQuery.query([wid]).first else { return }
            DispatchQueue.main.async {
                guard Windows.byWindowId[wid] == nil, let app = Applications.findOrCreate(pid, false) else { return }
                WindowServerEvents.subscribe(wid)
                Windows.findOrCreateCandidate(raw, app)
            }
        }
    }

    /// The facts the model needs but a reducer input does not carry. Closures because the live answers come
    /// from `Applications`/`TabGroups`, and tests supply their own.
    private static func context() -> AttentionDriver.Context {
        AttentionDriver.Context(
            generation: { pid in
                let generation = generations[pid] ?? 1
                generations[pid] = generation
                return ProcessGeneration(pid: pid, generation: generation)
            },
            pidOf: { wid in Windows.list.first { $0.cgWindowId == wid }?.application.pid },
            representativeOf: { wid in TabGroups.groupId(of: wid).flatMap { TabGroups.representativeByGroup[$0] } ?? wid },
            frontmostPid: { Applications.frontmostPid })
    }
}
