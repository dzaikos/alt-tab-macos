import Foundation

enum AxNotificationCapability: CaseIterable, Hashable {
    case focusedWindowChanged
    case mainWindowChanged
    /// **The title, pushed instead of polled.** There is no WindowServer title event, so before this the
    /// title was re-read from AX on every order-in, every order-out and every switcher show, and a title
    /// that changed between two shows was simply stale (the one live exposure named in the AX-to-WS event
    /// map: `matchSiblings` compares fresh AX tab titles against model window titles).
    ///
    /// It is in the core set rather than optional because it REPLACES work we were already doing against
    /// every app, and because it was measured to register on every app that owns user-facing windows.
    /// Unlike `kAXFocusedUIElementChanged` (which must never be subscribed) this is a window-level
    /// notification, not an element-level stream.
    case titleChanged
    /// **Optional and unproven.** A private notification some apps post when the selected tab changes. It is
    /// registered separately and its refusal is that notification's business alone: an app that does not
    /// support it is not an unhealthy app, and the health policy already treats `notificationUnsupported` as
    /// permanent for one capability rather than for the observer.
    ///
    /// It mutates nothing. A third-party investigation reported it arriving in pairs naming the outgoing and
    /// incoming tab, but follow-up testing found that wrong for Finder, for Merge All Windows, and for an
    /// ungrouped window joining a group — so it is measured here before it is believed anywhere.
    case focusedTabChanged

    /// **Off by default, and switchable on its own.** The probe registers a private notification on every
    /// app; nothing depends on the answer yet, and the set this provider actually needs must stay the narrow
    /// three that broad AX subscriptions taught us to keep it to.
    static var focusedTabProbeEnabled = false

    /// Whether this capability is part of the set every eligible process gets subscribed to.
    var isEnabled: Bool {
        self != .focusedTabChanged || Self.focusedTabProbeEnabled
    }
}

enum AxNotificationState: Equatable {
    case unattempted
    case subscribing
    case subscribed
    case unsupported
    case cooldown(until: MonotonicTimestamp)
}

enum AxProviderLifecycle: Equatable {
    case unregistered
    case registering
    case healthy
    case degraded
    case unresponsive
    case recovering
    case globalPermissionFailure
}

enum AxObserverError: Equatable {
    case notificationUnsupported
    case notImplemented
    case cannotComplete
    case invalidUIElement
    case apiDisabled
    case invalidObserver
    case invalidArgument
    case genericFailure
}

enum AxSubscriptionResult: Equatable {
    case success
    case alreadyRegistered
    case notificationUnsupported
    case notImplemented
    case cannotComplete
    case invalidUIElement
    case apiDisabled
    case invalidObserver
    case invalidArgument
    case genericFailure
}

enum AxRecoveryTrigger: Equatable {
    case processBecameFrontmost
    case windowDiscovered
    case semanticDomainDirty
    case wake
    case unlock
    case otherAxCallSucceeded
    case recoveryTick
}

struct AxObserverDiagnostics: Equatable {
    var attemptCount = 0
    var capabilityAttemptCounts = [AxNotificationCapability: Int]()
    var observerGeneration: UInt64 = 0
    var consecutiveCannotComplete = 0
    var capabilityConsecutiveCannotComplete = [AxNotificationCapability: Int]()
    var lastError: AxObserverError?
    var lastSuccess: MonotonicTimestamp?
    var lastCallback: MonotonicTimestamp?
    var nextRetry: MonotonicTimestamp?

    mutating func recordAttempt(_ capability: AxNotificationCapability) {
        attemptCount += 1
        capabilityAttemptCounts[capability, default: 0] += 1
    }

    mutating func recordCannotComplete(_ capability: AxNotificationCapability) -> Int {
        capabilityConsecutiveCannotComplete[capability, default: 0] += 1
        refreshCannotCompleteAggregate()
        return capabilityConsecutiveCannotComplete[capability, default: 0]
    }

    mutating func resetCannotComplete(_ capability: AxNotificationCapability) {
        capabilityConsecutiveCannotComplete[capability] = nil
        refreshCannotCompleteAggregate()
    }

    mutating func resetCannotComplete() {
        capabilityConsecutiveCannotComplete.removeAll(keepingCapacity: true)
        consecutiveCannotComplete = 0
    }

    private mutating func refreshCannotCompleteAggregate() {
        consecutiveCannotComplete = capabilityConsecutiveCannotComplete.values.max() ?? 0
    }
}

struct AxProcessObserverHealth: Equatable {
    let process: ProcessGeneration
    var lifecycle = AxProviderLifecycle.unregistered
    var notifications: [AxNotificationCapability: AxNotificationState]
    var diagnostics = AxObserverDiagnostics()

    init(process: ProcessGeneration) {
        self.process = process
        notifications = Dictionary(uniqueKeysWithValues: AxNotificationCapability.allCases.map { (
            $0,
            .unattempted
        ) })
    }

    var capabilities: Set<AxNotificationCapability> {
        Set(notifications.compactMap { $0.value == .subscribed ? $0.key : nil })
    }
}

struct AxObserverHealthState: Equatable {
    var entries = [Int32: AxProcessObserverHealth]()
    var hasGlobalPermissionFailure = false

    func entry(for process: ProcessGeneration) -> AxProcessObserverHealth? {
        guard let entry = entries[process.pid], entry.process == process else { return nil }
        return entry
    }
}

struct AxObserverRetryPolicy: Equatable {
    let shortRetryLimit: Int
    let initialRetryDelay: UInt64
    let maximumRetryDelay: UInt64
    /// The FIRST sparse wait, doubling up to `sparseCooldown`. A flat 30s here meant an app that was wedged
    /// when AltTab started and then began answering again waited out a full cooldown before anyone asked it
    /// anything, which for the user is half a minute of the switcher not offering windows that are on screen
    /// (WL-12). The growth costs a handful of extra attempts in the first minute against an app that is
    /// permanently silent, and nothing at all after that.
    let initialSparseDelay: UInt64
    let sparseCooldown: UInt64

    static let `default` = Self(shortRetryLimit: 4, initialRetryDelay: 100_000_000,
                                maximumRetryDelay: 800_000_000, initialSparseDelay: 1_000_000_000,
                                sparseCooldown: 30_000_000_000)
}

enum AxObserverHealthInput: Equatable {
    case processStarted(ProcessGeneration)
    case beginSubscription(ProcessGeneration, AxNotificationCapability)
    case subscriptionResult(ProcessGeneration, observerGeneration: UInt64, AxNotificationCapability,
                            AxSubscriptionResult, at: MonotonicTimestamp)
    case callback(ProcessGeneration, observerGeneration: UInt64, AxNotificationCapability,
                  at: MonotonicTimestamp)
    case recoveryTriggered(ProcessGeneration, AxRecoveryTrigger, at: MonotonicTimestamp)
    case cooldownElapsed(ProcessGeneration, at: MonotonicTimestamp)
    case globalPermissionRestored(at: MonotonicTimestamp)
    case teardown(ProcessGeneration)
}

enum AxObserverHealthIgnoreReason: Equatable {
    case unknownProcess
    case staleProcessGeneration
    case staleObserverGeneration
    case globalPermissionFailure
    case notificationState
    case cooldown
    case duplicateProcess
    case noRecoveryNeeded
}

enum AxObserverHealthDecision: Equatable {
    case processRegistered(ProcessGeneration)
    case processGenerationReplaced(ProcessGeneration, cancelledObserverGeneration: UInt64)
    case subscriptionStarted(AxNotificationCapability, observerGeneration: UInt64)
    case capabilitySubscribed(AxNotificationCapability)
    case capabilityUnsupported(AxNotificationCapability)
    case retryScheduled(AxNotificationCapability, at: MonotonicTimestamp, sparse: Bool)
    case observerRebuildRequired(cancelledGeneration: UInt64, replacementGeneration: UInt64)
    case callbackAccepted(AxNotificationCapability)
    case recoveryStarted(AxRecoveryTrigger)
    case globalPermissionFailed
    case globalRecoveryStarted([ProcessGeneration])
    case tornDown(cancelledObserverGeneration: UInt64)
    case ignored(AxObserverHealthIgnoreReason)
}

enum AxObserverHealth {
    static func reduce(_ state: inout AxObserverHealthState, _ input: AxObserverHealthInput,
                       policy: AxObserverRetryPolicy = .default) -> AxObserverHealthDecision {
        switch input {
        case let .processStarted(process): return processStarted(&state, process)
        case let .beginSubscription(process, capability):
            return beginSubscription(&state, process, capability)
        case let .subscriptionResult(process, generation, capability, result, time):
            return subscriptionResult(&state, process, generation, capability, result, time, policy)
        case let .callback(process, generation, capability, time):
            return callback(&state, process, generation, capability, time)
        case let .recoveryTriggered(process, trigger, time):
            return recovery(&state, process, trigger, time)
        case let .cooldownElapsed(process, time):
            return recovery(&state, process, .recoveryTick, time)
        case .globalPermissionRestored:
            return permissionRestored(&state)
        case let .teardown(process): return teardown(&state, process)
        }
    }

    private static func processStarted(_ state: inout AxObserverHealthState,
                                       _ process: ProcessGeneration) -> AxObserverHealthDecision {
        guard let previous = state.entries[process.pid] else {
            state.entries[process.pid] = newEntry(process, state.hasGlobalPermissionFailure)
            return .processRegistered(process)
        }
        guard previous.process != process else { return .ignored(.duplicateProcess) }
        state.entries[process.pid] = newEntry(process, state.hasGlobalPermissionFailure)
        return .processGenerationReplaced(previous.process,
                                          cancelledObserverGeneration: previous.diagnostics.observerGeneration)
    }

    private static func newEntry(_ process: ProcessGeneration,
                                 _ hasGlobalPermissionFailure: Bool) -> AxProcessObserverHealth {
        var entry = AxProcessObserverHealth(process: process)
        guard hasGlobalPermissionFailure else { return entry }
        entry.lifecycle = .globalPermissionFailure
        entry.diagnostics.lastError = .apiDisabled
        return entry
    }

    private static func beginSubscription(_ state: inout AxObserverHealthState, _ process: ProcessGeneration,
                                          _ capability: AxNotificationCapability)
        -> AxObserverHealthDecision {
        guard !state.hasGlobalPermissionFailure else { return .ignored(.globalPermissionFailure) }
        guard var entry = state.entries[process.pid] else { return .ignored(.unknownProcess) }
        guard entry.process == process else { return .ignored(.staleProcessGeneration) }
        guard entry.notifications[capability] == .unattempted else { return .ignored(.notificationState) }
        if entry.diagnostics.observerGeneration == 0 { entry.diagnostics.observerGeneration = 1 }
        entry.notifications[capability] = .subscribing
        entry.diagnostics.recordAttempt(capability)
        entry.lifecycle = entry.capabilities.isEmpty ? .registering : .recovering
        state.entries[process.pid] = entry
        return .subscriptionStarted(capability, observerGeneration: entry.diagnostics.observerGeneration)
    }

    private static func subscriptionResult(_ state: inout AxObserverHealthState, _ process: ProcessGeneration,
                                           _ generation: UInt64, _ capability: AxNotificationCapability,
                                           _ result: AxSubscriptionResult, _ time: MonotonicTimestamp,
                                           _ policy: AxObserverRetryPolicy) -> AxObserverHealthDecision {
        guard var entry = state.entries[process.pid] else { return .ignored(.unknownProcess) }
        guard entry.process == process else { return .ignored(.staleProcessGeneration) }
        guard entry.diagnostics.observerGeneration == generation
        else { return .ignored(.staleObserverGeneration) }
        guard entry.notifications[capability] == .subscribing else { return .ignored(.notificationState) }
        switch result {
        case .success, .alreadyRegistered:
            entry.notifications[capability] = .subscribed
            entry.diagnostics.lastSuccess = time
            entry.diagnostics.resetCannotComplete(capability)
            entry.diagnostics.nextRetry = nextRetry(entry)
            refreshLifecycle(&entry)
            state.entries[process.pid] = entry
            return .capabilitySubscribed(capability)
        case .notificationUnsupported, .notImplemented:
            entry.notifications[capability] = .unsupported
            entry.diagnostics.lastError = result == .notificationUnsupported
                ? .notificationUnsupported
                : .notImplemented
            entry.diagnostics.nextRetry = nextRetry(entry)
            refreshLifecycle(&entry)
            state.entries[process.pid] = entry
            return .capabilityUnsupported(capability)
        case .cannotComplete:
            return cannotComplete(&state, entry, capability, time, policy)
        case .invalidUIElement, .invalidObserver:
            return rebuild(&state, entry, result == .invalidUIElement ? .invalidUIElement : .invalidObserver)
        case .apiDisabled:
            return permissionFailed(&state)
        case .invalidArgument, .genericFailure:
            let error: AxObserverError = result == .invalidArgument ? .invalidArgument : .genericFailure
            return sparseFailure(&state, entry, capability, error, time, policy)
        }
    }

    private static func callback(_ state: inout AxObserverHealthState, _ process: ProcessGeneration,
                                 _ generation: UInt64, _ capability: AxNotificationCapability,
                                 _ time: MonotonicTimestamp) -> AxObserverHealthDecision {
        guard var entry = state.entries[process.pid] else { return .ignored(.unknownProcess) }
        guard entry.process == process else { return .ignored(.staleProcessGeneration) }
        guard entry.diagnostics.observerGeneration == generation
        else { return .ignored(.staleObserverGeneration) }
        guard entry.notifications[capability] == .subscribed else { return .ignored(.notificationState) }
        entry.diagnostics.lastCallback = time
        entry.diagnostics.lastSuccess = time
        entry.diagnostics.resetCannotComplete(capability)
        refreshLifecycle(&entry)
        state.entries[process.pid] = entry
        return .callbackAccepted(capability)
    }

    private static func cannotComplete(_ state: inout AxObserverHealthState, _ entry: AxProcessObserverHealth,
                                       _ capability: AxNotificationCapability, _ time: MonotonicTimestamp,
                                       _ policy: AxObserverRetryPolicy) -> AxObserverHealthDecision {
        var entry = entry
        let refusalCount = entry.diagnostics.recordCannotComplete(capability)
        let sparse = refusalCount > policy.shortRetryLimit
        let delay = sparse
            ? sparseDelay(refusalCount - policy.shortRetryLimit, policy)
            : exponentialDelay(refusalCount, policy)
        let retry = adding(delay, to: time)
        entry.notifications[capability] = .cooldown(until: retry)
        entry.lifecycle = .unresponsive
        entry.diagnostics.lastError = .cannotComplete
        entry.diagnostics.nextRetry = nextRetry(entry)
        state.entries[entry.process.pid] = entry
        return .retryScheduled(capability, at: retry, sparse: sparse)
    }

    private static func sparseFailure(_ state: inout AxObserverHealthState, _ entry: AxProcessObserverHealth,
                                      _ capability: AxNotificationCapability, _ error: AxObserverError,
                                      _ time: MonotonicTimestamp,
                                      _ policy: AxObserverRetryPolicy) -> AxObserverHealthDecision {
        var entry = entry
        let retry = adding(policy.sparseCooldown, to: time)
        entry.notifications[capability] = .cooldown(until: retry)
        entry.lifecycle = .degraded
        entry.diagnostics.lastError = error
        entry.diagnostics.nextRetry = nextRetry(entry)
        state.entries[entry.process.pid] = entry
        return .retryScheduled(capability, at: retry, sparse: true)
    }

    private static func rebuild(_ state: inout AxObserverHealthState, _ entry: AxProcessObserverHealth,
                                _ error: AxObserverError) -> AxObserverHealthDecision {
        var entry = entry
        let cancelled = entry.diagnostics.observerGeneration
        entry.diagnostics.observerGeneration &+= 1
        entry.diagnostics.lastError = error
        entry.diagnostics.resetCannotComplete()
        entry.diagnostics.nextRetry = nil
        resetAttemptableCapabilities(&entry)
        entry.lifecycle = .recovering
        state.entries[entry.process.pid] = entry
        return .observerRebuildRequired(cancelledGeneration: cancelled,
                                        replacementGeneration: entry.diagnostics.observerGeneration)
    }

    private static func permissionFailed(_ state: inout AxObserverHealthState) -> AxObserverHealthDecision {
        state.hasGlobalPermissionFailure = true
        for pid in Array(state.entries.keys) {
            guard var entry = state.entries[pid] else { continue }
            resetAttemptableCapabilities(&entry)
            entry.lifecycle = .globalPermissionFailure
            entry.diagnostics.lastError = .apiDisabled
            entry.diagnostics.nextRetry = nil
            state.entries[pid] = entry
        }
        return .globalPermissionFailed
    }

    private static func permissionRestored(_ state: inout AxObserverHealthState) -> AxObserverHealthDecision {
        guard state.hasGlobalPermissionFailure else { return .ignored(.noRecoveryNeeded) }
        state.hasGlobalPermissionFailure = false
        for pid in Array(state.entries.keys) {
            guard var entry = state.entries[pid] else { continue }
            if entry.diagnostics.observerGeneration > 0 { entry.diagnostics.observerGeneration &+= 1 }
            entry.lifecycle = .recovering
            state.entries[pid] = entry
        }
        return .globalRecoveryStarted(state.entries.values.map(\.process).sorted())
    }

    private static func recovery(_ state: inout AxObserverHealthState, _ process: ProcessGeneration,
                                 _ trigger: AxRecoveryTrigger,
                                 _ time: MonotonicTimestamp) -> AxObserverHealthDecision {
        guard !state.hasGlobalPermissionFailure else { return .ignored(.globalPermissionFailure) }
        guard var entry = state.entries[process.pid] else { return .ignored(.unknownProcess) }
        guard entry.process == process else { return .ignored(.staleProcessGeneration) }
        let bypassCooldown = trigger == .otherAxCallSucceeded
        let recoverable = entry.notifications.filter {
            guard case let .cooldown(until) = $0.value else { return false }
            return bypassCooldown || time >= until
        }.map(\.key)
        guard !recoverable.isEmpty else {
            return .ignored(entry.diagnostics.nextRetry == nil ? .noRecoveryNeeded : .cooldown)
        }
        for capability in recoverable { entry.notifications[capability] = .unattempted }
        if bypassCooldown {
            entry.diagnostics.lastSuccess = time
        }
        entry.diagnostics.nextRetry = nextRetry(entry)
        entry.lifecycle = .recovering
        state.entries[process.pid] = entry
        return .recoveryStarted(trigger)
    }

    private static func teardown(_ state: inout AxObserverHealthState,
                                 _ process: ProcessGeneration) -> AxObserverHealthDecision {
        guard let entry = state.entries[process.pid] else { return .ignored(.unknownProcess) }
        guard entry.process == process else { return .ignored(.staleProcessGeneration) }
        state.entries[process.pid] = nil
        return .tornDown(cancelledObserverGeneration: entry.diagnostics.observerGeneration)
    }

    private static func resetAttemptableCapabilities(_ entry: inout AxProcessObserverHealth) {
        for capability in AxNotificationCapability.allCases {
            if entry.notifications[capability] != .unsupported {
                entry.notifications[capability] = .unattempted
            }
        }
    }

    private static func refreshLifecycle(_ entry: inout AxProcessObserverHealth) {
        let hasCooldown = entry.notifications.values.contains {
            if case .cooldown = $0 { return true }; return false
        }
        if hasCooldown { entry.lifecycle = .degraded }
        else if !entry.capabilities.isEmpty { entry.lifecycle = .healthy }
        else if entry.notifications.values.contains(.subscribing) { entry.lifecycle = .registering }
        else { entry.lifecycle = .degraded }
    }

    private static func nextRetry(_ entry: AxProcessObserverHealth) -> MonotonicTimestamp? {
        entry.notifications.values.compactMap {
            if case let .cooldown(until) = $0 { return until }; return nil
        }.min()
    }

    /// `tier` counts from 1 at the first sparse failure: 1s, 2s, 4s … up to the cooldown, and there forever.
    private static func sparseDelay(_ tier: Int, _ policy: AxObserverRetryPolicy) -> UInt64 {
        var delay = min(policy.initialSparseDelay, policy.sparseCooldown)
        for _ in 1 ..< max(tier, 1) { delay = min(policy.sparseCooldown, adding(delay, to: delay)) }
        return delay
    }

    private static func exponentialDelay(_ attempt: Int, _ policy: AxObserverRetryPolicy) -> UInt64 {
        guard attempt > 1 else { return min(policy.initialRetryDelay, policy.maximumRetryDelay) }
        var delay = min(policy.initialRetryDelay, policy.maximumRetryDelay)
        for _ in 1 ..< attempt { delay = min(policy.maximumRetryDelay, adding(delay, to: delay)) }
        return delay
    }

    private static func adding(_ value: UInt64, to time: MonotonicTimestamp) -> MonotonicTimestamp {
        MonotonicTimestamp(rawValue: adding(value, to: time.rawValue))
    }

    private static func adding(_ lhs: UInt64, to rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}
