import Cocoa
import ApplicationServices

/// **One `AXObserver` per live process generation, and nothing per window.**
///
/// An observer created for a pid and subscribed on the APPLICATION element receives the descendant window
/// notifications this needs. Per-window observers are therefore redundant, and orphaned per-window runloop
/// sources caused #5612's reported 399 GB virtual-memory growth. The observer count here is one per eligible
/// process and is independent of how many windows that process has.
///
/// This provider contributes SEMANTICS only — which window an app considers focused or main. It is never
/// asked what windows exist: that is the WindowServer's, and an AX failure must not remove a window, block
/// another process, or delay the switcher's first frame.
///
/// Results feed `AttentionDriver`, which is what turns them into a window order, and telemetry.
///
/// Threading: `observers` and `health` belong to `BackgroundWork.axSemanticsThread` and are only touched
/// there. Callbacks arrive on that thread and hand any IPC to `AXCallScheduler`, so a wedged app stalls its
/// own bounded call and not the runloop every other app's notifications arrive on.
class AxObserverRegistry {
    static let shared = AxObserverRegistry()

    private var observers = [pid_t: ObserverEntry]()
    private var health = AxObserverHealthState()
    /// The pids whose observer currently holds a live `titleChanged` subscription. `health` belongs to the
    /// AX thread, but the decision "may this window's title read be skipped" is taken on main, on the event
    /// path, so the one bit main needs is mirrored here. An app missing from it is simply read the old way,
    /// which is why losing an entry can never lose a title.
    private static let titleCapablePids = ConcurrentMap<pid_t, Bool>()

    /// Whether this app pushes its title changes, so a title-only AX read for one of its windows is work
    /// the notification has already done (`Applications.refreshWindowTitleAndTabs`).
    static func deliversTitles(_ pid: pid_t) -> Bool {
        titleCapablePids.withLock { $0[pid] != nil }
    }

    private struct ObserverEntry {
        let process: ProcessGeneration
        let observer: AXObserver
        let element: AXUIElement
        let observerGeneration: UInt64
        var sourceInstalled = false
    }

    /// AltTab's own process is excluded: a same-process AX read runs AppKit on the CALLING thread, and this
    /// provider's whole point is to do that work off-main. `AXUIElement.onCorrectThread` exists for the reads
    /// we cannot avoid; an observer we can simply not create.
    func processStarted(_ pid: pid_t) {
        guard pid != AXUIElement.currentProcessPid else { return }
        let process = ProcessGeneration(pid: pid, generation: AttentionEngine.generation(of: pid))
        onAxThread { self.register(process) }
    }

    /// **Generation-checked.** Called both from the explicit quit path and from `Application.deinit`, and a
    /// deinit can land AFTER a replacement process has already registered under the reused pid. Tearing down
    /// by pid alone would then kill the live observer of the new process.
    func processExited(_ pid: pid_t, generation: UInt64) {
        onAxThread {
            guard self.observers[pid]?.process.generation == generation else { return }
            self.teardown(pid)
        }
    }

    /// Bounded re-probe triggers. A timer changes HEALTH only: it can start a subscription attempt, and it
    /// can never turn an ambiguous WindowServer event into focus.
    func recover(_ pid: pid_t, _ trigger: AxRecoveryTrigger) {
        onAxThread { self.recoverOnAxThread(pid, trigger) }
    }

    private func recoverOnAxThread(_ pid: pid_t, _ trigger: AxRecoveryTrigger) {
        guard let entry = observers[pid] else { return }
        let decision = AxObserverHealth.reduce(&health,
            .recoveryTriggered(entry.process, trigger, at: Self.now()))
        guard case .recoveryStarted = decision else { return }
        subscribeAll(entry.process)
        publishHealth(entry.process)
    }

    /// **The sparse recovery tick.** Every other trigger needs something to happen — an activation, a wake,
    /// an unlock. An app that was wedged and quietly starts answering again causes none of them, so without a
    /// tick it stays quarantined until the user happens to activate it. The health policy refuses anything
    /// not actually in cooldown, so this costs one pass over the table.
    func startRecoveryTicks() {
        scheduleRecoveryTick()
    }

    private func scheduleRecoveryTick() {
        BackgroundWork.axSemanticsThread?.asyncAfter(Self.recoveryTickInterval) { [weak self] in
            self?.recoverAll(.recoveryTick)
            self?.scheduleRecoveryTick()
        }
    }

    /// A BACKSTOP, not the retry driver: every cooldown schedules its own expiry (`scheduleRetry`), and this
    /// only catches an entry whose timer was lost. Matched to the sparse cooldown, because a shorter tick
    /// only asks a silent app more often for the same answer, and every ask is an AX call to a process that
    /// is not listening.
    private static let recoveryTickInterval: Double = 30

    /// Every process at once, for a system-wide event. Cheap: `recoveryTriggered` refuses anything already
    /// healthy, so a wake costs one pass over the table and a subscription attempt only where one is owed.
    func recoverAll(_ trigger: AxRecoveryTrigger) {
        onAxThread {
            for pid in self.observers.keys { self.recoverOnAxThread(pid, trigger) }
        }
    }

    // MARK: registration

    private func register(_ process: ProcessGeneration) {
        let decision = AxObserverHealth.reduce(&health, .processStarted(process))
        if case let .processGenerationReplaced(previous, _) = decision { releaseObserver(previous.pid) }
        guard decision != .ignored(.duplicateProcess) else { return }
        guard let entry = makeObserver(process) else { return }
        observers[process.pid] = entry
        installSource(entry)
        subscribeAll(process)
        publishHealth(process)
    }

    /// Every `AXObserverCreate` result is checked. The old code force-unwrapped the observer and asked in a
    /// comment whether it could ever be nil; it can, for a process that is already gone.
    private func makeObserver(_ process: ProcessGeneration) -> ObserverEntry? {
        var observer: AXObserver?
        let result = AXObserverCreate(process.pid, Self.callback, &observer)
        guard result == .success, let observer else {
            TrackingTelemetryRecorder.axProviderFailed(process, Self.error(from: result))
            return nil
        }
        let generation = health.entry(for: process)?.diagnostics.observerGeneration ?? 1
        return ObserverEntry(process: process, observer: observer,
            element: AXUIElementCreateApplication(process.pid), observerGeneration: max(generation, 1))
    }

    /// **`.commonModes`, and installed exactly once.** A source added in the default mode alone stops
    /// delivering while a scroll or a menu tracking loop is up, which is how notifications used to disappear
    /// mid-gesture.
    private func installSource(_ entry: ObserverEntry) {
        guard !entry.sourceInstalled, let runLoop = BackgroundWork.axSemanticsThread?.runLoop else { return }
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(entry.observer), .commonModes)
        observers[entry.process.pid]?.sourceInstalled = true
    }

    /// Deliberately narrow. `kAXFocusedUIElementChanged` is NOT here and must never be: subscribing to it
    /// harmed JetBrains-derived apps, LibreOffice and MATLAB, and it was removed for that reason.
    private func subscribeAll(_ process: ProcessGeneration) {
        for capability in AxNotificationCapability.allCases where capability.isEnabled {
            subscribe(process, capability)
        }
    }

    private func subscribe(_ process: ProcessGeneration, _ capability: AxNotificationCapability) {
        let begun = AxObserverHealth.reduce(&health, .beginSubscription(process, capability))
        guard case let .subscriptionStarted(_, observerGeneration) = begun,
              let entry = observers[process.pid], entry.process == process else { return }
        let refcon = Self.packRefcon(pid: process.pid, observerGeneration: observerGeneration)
        AXCallScheduler.shared.schedule(key: "axobs-\(process.pid)-\(capability.telemetryName)",
                                        context: "axSemantics", pid: process.pid) {
            let result = entry.element.addNotification(entry.observer, capability.notificationName, refcon)
            if result != .success && result != .notificationAlreadyRegistered {
                Logger.debug { "axobs pid=\(process.pid) \(capability.telemetryName) refused \(result.rawValue)" }
            }
            self.onAxThread {
                self.applySubscriptionResult(process, observerGeneration, capability, Self.result(from: result))
            }
        }
    }

    private func applySubscriptionResult(_ process: ProcessGeneration, _ observerGeneration: UInt64,
                                         _ capability: AxNotificationCapability,
                                         _ result: AxSubscriptionResult) {
        let hadNothing = health.entry(for: process)?.capabilities.isEmpty ?? true
        let decision = AxObserverHealth.reduce(&health, .subscriptionResult(process,
            observerGeneration: observerGeneration, capability, result, at: Self.now()))
        publishHealth(process)
        // **Rescan when an app STARTS ANSWERING, not when we ask it to.** An app that is permanently silent
        // is asked again on every sparse retry, and firing a whole-machine rescan per attempt cost 903 of
        // them in 55 minutes of ordinary use — measured, with six such apps on the machine. A rescan is only
        // owed when a process that had no working subscriptions gains one: that is the moment its windows
        // may be acquirable at last.
        if hadNothing, case .capabilitySubscribed = decision {
            DispatchQueue.main.async { Applications.manuallyRefreshAllWindows() }
        }
        switch decision {
        case let .retryScheduled(_, at, _): scheduleRetry(process, at)
        case .observerRebuildRequired: rebuild(process)
        case .globalPermissionFailed: Logger.debug { "ax provider: accessibility API disabled" }
        default: break
        }
    }

    /// The retry budget lives in the pure policy; this only obeys the deadline it returned. The old
    /// implementation retried every 10ms forever, which is the failure this separation exists to prevent.
    ///
    /// **The cooldown has to be RELEASED before another attempt is possible.** A capability sitting in
    /// `.cooldown` refuses `beginSubscription`, so calling `subscribe` straight from here did nothing at all
    /// and the only thing retrying anything was the sparse tick — which is why a wedged app that started
    /// answering again took up to a tick plus a cooldown to come back.
    private func scheduleRetry(_ process: ProcessGeneration, _ deadline: MonotonicTimestamp) {
        let delay = Double(deadline.rawValue &- Self.now().rawValue) / 1_000_000_000
        BackgroundWork.axSemanticsThread?.asyncAfter(max(delay, 0)) {
            guard self.health.entry(for: process) != nil else { return }
            let decision = AxObserverHealth.reduce(&self.health, .cooldownElapsed(process, at: Self.now()))
            guard case .recoveryStarted = decision else { return }
            self.subscribeAll(process)
            self.publishHealth(process)
        }
    }

    /// An element that outlived its window (Electron and Zoom replace one without sending a destroy) makes
    /// every later call return `.invalidUIElement`. The cure is a new observer generation, not a retry.
    private func rebuild(_ process: ProcessGeneration) {
        releaseObserver(process.pid)
        guard let entry = makeObserver(process) else { return }
        observers[process.pid] = entry
        installSource(entry)
        subscribeAll(process)
    }

    // MARK: teardown

    /// **Synchronous invalidation.** The runloop source is removed explicitly rather than left to the
    /// observer's deallocation: orphaned sources are what leaked in #5612, and a source still installed keeps
    /// delivering into a generation that no longer exists.
    private func teardown(_ pid: pid_t) {
        guard let entry = observers[pid] else { return }
        _ = AxObserverHealth.reduce(&health, .teardown(entry.process))
        releaseObserver(pid)
    }

    private static func setTitleCapability(_ pid: pid_t, _ delivers: Bool) {
        titleCapablePids.withLock { delivers ? ($0[pid] = true) : ($0[pid] = nil) }
    }

    private func releaseObserver(_ pid: pid_t) {
        Self.setTitleCapability(pid, false)
        guard let entry = observers.removeValue(forKey: pid) else { return }
        guard let runLoop = BackgroundWork.axSemanticsThread?.runLoop else { return }
        CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(entry.observer), .commonModes)
    }

    // MARK: callbacks

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let (pid, observerGeneration) = unpackRefcon(refcon),
              let capability = AxNotificationCapability(notificationName: notification as String) else { return }
        shared.handle(pid, observerGeneration, capability, element)
    }

    /// Runs on the observer thread. It captures, it does not read: the only IPC a semantic edge needs is the
    /// element's wid, and that goes to the bounded pool so a wedged app cannot hold this runloop.
    private func handle(_ pid: pid_t, _ observerGeneration: UInt64, _ capability: AxNotificationCapability,
                        _ element: AXUIElement) {
        guard let entry = observers[pid], entry.observerGeneration == observerGeneration else { return }
        let decision = AxObserverHealth.reduce(&health, .callback(entry.process,
            observerGeneration: observerGeneration, capability, at: Self.now()))
        guard case .callbackAccepted = decision else { return }
        TrackingTelemetryRecorder.axNotification(pid)
        // Measured, never believed: a focused-tab notification is recorded with the window it named and
        // nothing else happens. Its production role is decided from the capture, not assumed here.
        guard capability != .focusedTabChanged else { return recordTabSignal(entry.process, element) }
        guard capability != .titleChanged else { return refreshTitle(entry.process, element) }
        resolveWid(entry.process, element)
    }

    /// **The title, straight from the app that changed it.** Reads the wid and the title in one scheduled
    /// block and hands both to the model, which is what lets `Applications.refreshWindowTitleAndTabs` stop
    /// asking for a title the app has already told us.
    ///
    /// Both reads are `try?`, so this never throws and the scheduler's retry/backoff never engages. A retry
    /// would re-ask a question that has moved on (the title changed again, or the window is gone), and the
    /// per-show pass re-reads the title for anything this missed. The per-key hold in `AXCallScheduler` plus
    /// the per-wid throttle on the apply side are what bound an app that renames its window continuously.
    private func refreshTitle(_ process: ProcessGeneration, _ element: AXUIElement) {
        AXCallScheduler.shared.schedule(key: "axobs-title-\(process.pid)", context: "axSemantics",
                                        pid: process.pid) {
            guard let wid = try? element.cgWindowId(pid: process.pid), wid != 0,
                  let title = try? element.attributes([kAXTitleAttribute], pid: process.pid).title else { return }
            DispatchQueue.main.async { Applications.applyObservedTitle(wid: wid, title: title) }
        }
    }

    private func recordTabSignal(_ process: ProcessGeneration, _ element: AXUIElement) {
        AXCallScheduler.shared.schedule(key: "axobs-tab-\(process.pid)", context: "axSemantics",
                                        pid: process.pid) {
            let wid = try element.cgWindowId(pid: process.pid)
            DispatchQueue.main.async {
                TrackingTelemetryRecorder.axFocusedTabSignal(pid: process.pid, wid: wid)
            }
        }
    }

    /// **Not cached by element.** Two `AXUIElement`s for one window are different objects that `CFEqual`
    /// considers the same, and their `CFHash` is not unique, so a cache keyed either way can hand back
    /// another window's id. `_AXUIElementGetWindow` is the cheapest AX call there is and a semantic edge is
    /// rare — a focus change, not a stream — so it is read each time, on the bounded pool.
    private func resolveWid(_ process: ProcessGeneration, _ element: AXUIElement) {
        AXCallScheduler.shared.schedule(key: "axobs-wid-\(process.pid)", context: "axSemantics",
                                        pid: process.pid) {
            let wid = try element.cgWindowId(pid: process.pid)
            self.onAxThread {
                // The process may have died, or been replaced by a new generation, while the read was out.
                guard self.observers[process.pid]?.process == process else { return }
                self.publishSemantic(process, wid)
            }
        }
    }

    private func publishSemantic(_ process: ProcessGeneration, _ wid: CGWindowID) {
        guard wid != 0 else { return }
        DispatchQueue.main.async { AttentionEngine.axSemanticFocus(pid: process.pid, wid: wid) }
    }

    private func publishHealth(_ process: ProcessGeneration) {
        guard let entry = health.entry(for: process) else { return }
        let capabilities = Array(entry.capabilities)
        Self.setTitleCapability(process.pid, capabilities.contains(.titleChanged))
        let diagnostics = entry.diagnostics
        let lifecycle = entry.lifecycle
        DispatchQueue.main.async {
            TrackingTelemetryRecorder.axProviderHealth(pid: process.pid, state: lifecycle,
                observerGeneration: diagnostics.observerGeneration, attempts: diagnostics.attemptCount,
                capabilities: capabilities, lastError: diagnostics.lastError)
        }
    }

    // MARK: plumbing

    private func onAxThread(_ block: @escaping () -> Void) {
        guard let thread = BackgroundWork.axSemanticsThread else { return }
        thread.async(block)
    }

    private static func now() -> MonotonicTimestamp {
        MonotonicTimestamp(rawValue: DispatchTime.now().uptimeNanoseconds)
    }

    /// Process identity travels in the refcon rather than being asked for over IPC on every delivery. The
    /// observer generation rides with it so a callback from a rebuilt observer is recognisably stale.
    private static func packRefcon(pid: pid_t, observerGeneration: UInt64) -> UnsafeMutableRawPointer? {
        let packed = UInt(UInt32(bitPattern: pid)) << 32 | UInt(observerGeneration & 0xFFFF_FFFF)
        return UnsafeMutableRawPointer(bitPattern: packed)
    }

    private static func unpackRefcon(_ refcon: UnsafeMutableRawPointer?) -> (pid_t, UInt64)? {
        guard let refcon else { return nil }
        let packed = UInt(bitPattern: refcon)
        return (pid_t(Int32(bitPattern: UInt32(packed >> 32))), UInt64(packed & 0xFFFF_FFFF))
    }

    /// Each AX result gets its own state, rather than one retry bucket for every failure. `.cannotComplete`
    /// is a busy process and cools down; `.notificationUnsupported` is permanent for THAT notification only
    /// and must not mark the whole observer unhealthy; `.apiDisabled` is global and must not be hammered per
    /// pid.
    private static func result(from error: AXError) -> AxSubscriptionResult {
        switch error {
        case .success: return .success
        case .notificationAlreadyRegistered: return .alreadyRegistered
        case .notificationUnsupported: return .notificationUnsupported
        case .notImplemented: return .notImplemented
        case .cannotComplete: return .cannotComplete
        case .invalidUIElement: return .invalidUIElement
        case .invalidUIElementObserver: return .invalidObserver
        // **Only OUR permission being gone is global.** Measured: several processes on a machine with
        // Accessibility granted still answer `kAXErrorAPIDisabled` (-25211) for their own reasons. Passing
        // that straight through set the provider's global-permission flag and every later subscription for
        // EVERY app was refused before it was attempted — 138 successful subscriptions, then silence. So the
        // escalation is gated on `AXIsProcessTrusted`, and an individual app's refusal is a per-pid
        // temporary failure like any other.
        case .apiDisabled: return AXIsProcessTrusted() ? .cannotComplete : .apiDisabled
        case .illegalArgument: return .invalidArgument
        default: return .genericFailure
        }
    }

    private static func error(from result: AXError) -> AxObserverError {
        switch result {
        case .cannotComplete: return .cannotComplete
        case .invalidUIElement: return .invalidUIElement
        // **Only OUR permission being gone is global.** Measured: several processes on a machine with
        // Accessibility granted still answer `kAXErrorAPIDisabled` (-25211) for their own reasons. Passing
        // that straight through set the provider's global-permission flag and every later subscription for
        // EVERY app was refused before it was attempted — 138 successful subscriptions, then silence. So the
        // escalation is gated on `AXIsProcessTrusted`, and an individual app's refusal is a per-pid
        // temporary failure like any other.
        case .apiDisabled: return AXIsProcessTrusted() ? .cannotComplete : .apiDisabled
        case .illegalArgument: return .invalidArgument
        default: return .genericFailure
        }
    }
}

extension AxNotificationCapability {
    var notificationName: String {
        switch self {
        case .focusedWindowChanged: return kAXFocusedWindowChangedNotification
        case .mainWindowChanged: return kAXMainWindowChangedNotification
        case .titleChanged: return kAXTitleChangedNotification
        case .focusedTabChanged: return "AXFocusedTabChanged"
        }
    }


    init?(notificationName: String) {
        guard let match = Self.allCases.first(where: { $0.notificationName == notificationName }) else {
            return nil
        }
        self = match
    }
}
