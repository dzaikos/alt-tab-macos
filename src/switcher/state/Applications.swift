import Cocoa
import ApplicationServices

class Applications {
    static var list = [Application]()
    static var frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    // Throttlers coalesce redundant work. They are SEPARATE from AXCallScheduler, which is a pure executor
    // (bounded pools + retry, no throttle). Each one below states what it coalesces and why:
    // A — suppress redundant inbound events: coalesce resize/move/title bursts to ≤1 attribute read per window
    static let windowAttributesThrottler = ThrottlerWithKey(delayInMs: 200)
    // B — suppress redundant recompute: ≤1 full window-inventory scan per second (on switcher show)
    static let fullRescanThrottler = Throttler(delayInMs: 1000)
    // B — ≤1 Dock-badge fetch per second
    static let dockBadgeThrottler = Throttler(delayInMs: 1000)
    // C — cap a resource: ≤1 thumbnail capture per window per 200ms
    static let screenshotThrottler = ThrottlerWithKey(delayInMs: 200)
    /// Wids whose close the OS confirmed twice (`removeIfClosedAfterOrderOut`) while CGS still lists them.
    /// CGS keeps a closed wid in its all-Space list for seconds, and some apps (Slack) keep handing back a
    /// live `AXWindow` element for it by brute-force, so the inventory sweep re-acquired the corpse it had
    /// just removed — the window came back for one summon, was flagged phantom on the next, and only then got
    /// its app's placeholder (#5849). Suppresses the SWEEP only; see `refreshWindowsViaWindowServer`.
    static var widsConfirmedClosed = Set<CGWindowID>()
    /// Surfaces the inventory sweep could not acquire an AX element for, with the app window-set version it
    /// failed at and how many attempts that situation has spent (`SurfaceAcquisitionPolicy`). Keyed by wid;
    /// the pid rides along so an app quitting can drop its entries. Cleared on a successful acquisition, on
    /// the wid being re-created, on window removal, on app quit, and whenever the WindowServer stops listing
    /// the wid at all.
    static var failedAcquisitions = [CGWindowID: (pid: pid_t, situation: UInt64, attempts: Int)]()

    /// Pids the discovery path has already refused, and what they were refused as. Read through
    /// `ApplicationVerdictCache.refusalStillAnswers`, which owns both rules (discovery-only, bundle id must
    /// still match) and says why each is load-bearing. Dropped in `removeRunningApplications` alongside the
    /// other per-pid caches.
    static var refusedByDiscovery = [pid_t: RefusedApplication]()

    static func noteAcquisitionFailed(_ wid: CGWindowID, _ pid: pid_t, _ situation: UInt64) {
        let previous = failedAcquisitions[wid]
        let attempts = SurfaceAcquisitionPolicy.attemptsAfterFailure(
            previousAttempts: previous?.attempts ?? 0, sameSituation: previous?.situation == situation)
        failedAcquisitions[wid] = (pid, situation, attempts)
        guard SurfaceAcquisitionPolicy.hasGivenUp(attempts: attempts) else { return }
        Windows.dropUndescribedAttentionAdmission(wid)
    }

    static func forgetAcquisitionFailure(_ wid: CGWindowID) {
        failedAcquisitions[wid] = nil
    }

    static func initialDiscovery() {
        addInitialRunningApplications()
        RunningApplicationsEvents.observe()
    }

    static func addInitialRunningApplications() {
        addRunningApplications(NSWorkspace.shared.runningApplications, false)
    }

    /// The four correction passes, fired together behind the fixed throttle.
    static func manuallyRefreshAllWindows() {
        fullRescanThrottler.throttleOrProceed {
            syncSpacesState()
            refreshWindowsViaWindowServer()
            reviewExistingWindows()
            discardDeadPhantomWindows()
        }
    }

    /// Discard "zombie" windows so they can't accumulate. Window removal is normally driven by the per-window
    /// destroy event (804), which is reliable for windows we're subscribed to. But our discovery is async — a
    /// window seen in the SLS snapshot can die in the gap before we subscribe to it, so its 804 fires before
    /// we're listening and never removes it; it lingers flagged phantom (empty spaceIds) and would otherwise
    /// pile up forever, holding a Window + a stale subscription each. So on each refresh, reconcile ONLY the
    /// windows currently flagged phantom (the accumulation candidates — usually none) against authoritative
    /// OS existence, and drop the ones the OS confirms gone. Alive-but-phantom windows (a real window briefly
    /// between Spaces, or Slack's empty-spaceIds case #5791) still exist, so they're kept and stay correctly
    /// hidden. Bails on query failure — never discard on incomplete data. (yabai sidesteps this race by
    /// observing a window synchronously at create; our discovery is async, so this is the cheap, scoped
    /// backstop — it checks the suspicious few, not the whole list.)
    static func discardDeadPhantomWindows() {
        let phantomWids = Windows.list.compactMap { $0.isPhantom ? $0.cgWindowId : nil }
        guard !phantomWids.isEmpty else { return }
        CGSCallScheduler.existingWindowIds(among: phantomWids) { alive in
            // Never discard on incomplete data.
            guard let alive else { return }
            let dead = Windows.list.filter { $0.isPhantom && ($0.cgWindowId.map { !alive.contains($0) } ?? false) }
            guard !dead.isEmpty else { return }
            Logger.debug { "remove phantomSweep count=\(dead.count) \(dead.map { $0.debugId })" }
            Windows.removeWindows(dead, true)
            // CGS itself says these wids no longer exist, so unlike every other removal there is nothing left
            // to come back; drop the opt-in `removeWindows` deliberately keeps.
            dead.compactMap { $0.cgWindowId }.forEach { WindowServerEvents.unsubscribe($0) }
        }
    }

    /// Refresh Space topology + per-window Space/screen membership via SkyLight, OFF the main thread, then
    /// reconcile the open switcher only if something moved. This is the per-summon Space refresh that used
    /// to block `Windows.updatesBeforeShowing` (#5721) — relocated here (runs ~0.25s after show, throttled),
    /// and first so its correction lands before the best-effort window passes. Mirrors `refreshIsPhantom`'s
    /// capture-on-main → query-off-main → apply-on-main pattern.
    static func syncSpacesState() {
        let mainScreenUuid = Spaces.mainScreenUuid()
        let trackedWids = Windows.list.compactMap { $0.cgWindowId }
        CGSCallScheduler.run {
            let snapshot = Spaces.query(mainScreenUuid, includeWindowMap: true)
            // #5791: the inverted per-Space enumeration can miss a window (e.g. Slack), leaving it absent from
            // the map → empty spaceIds → flagged phantom → hidden ("No Window"). Backfill any tracked wid the
            // map missed with a per-window CGSCopySpacesForWindows (off-main; only the misses pay, usually none).
            var windowToSpacesMap = snapshot.windowToSpacesMap
            var backfillProbe = [String]()
            for wid in trackedWids where windowToSpacesMap[wid] == nil {
                let spaces = CGSCallScheduler.windowSpaces(wid)
                // What this per-window query answers for a BACKGROUNDED TAB decides whether the re-query can
                // ever strip a group of its claim — the rec24 vanish. `sp[]` means the enumeration and the
                // per-window query agree the tab is nowhere; a non-empty answer means the tab keeps a stale
                // Space and the group is never wiped. Logged because the test model has to assume one.
                backfillProbe.append("#\(wid)→\(spaces.map { "\($0)" } ?? "noAnswer")")
                if let spaces, !spaces.isEmpty { windowToSpacesMap[wid] = spaces }
            }
            // CORROBORATE the wids both reads left unplaced, because "no Space" is not what an empty answer
            // means. CGS returns a non-NULL EMPTY array for a wid it has no record of at all (measured on
            // macOS 26: wid 0, 1, 999999, UINT32_MAX all answer `[]`), so dead-wid, genuinely-unplaced and
            // failed-read are one value here — and the reducer used to hide the window on all three. A
            // WindowServer row with a Space type is a SECOND read that disagrees, and a window two OS reads
            // disagree about is not one to hide: the reducer keeps its last known membership (#5954). One
            // batched IPC, only for the misses — usually none.
            //
            // Deliberately not read as "this window is definitely alive and definitely on a Space". Measured:
            // the WindowServer keeps a full row, `spaceTypeMask` unchanged, for a window CLOSED while its app
            // keeps running — so this says "the WindowServer has not forgotten this wid", which is weaker.
            // It is enough here because it only ever RETAINS a membership CGS itself reported earlier, and
            // because the strong-signal phantoms it must not resurrect (Joplin / Sprig / `show:false`
            // Electron) are caught by a separate pipeline that this cannot reach: `cgsWindowListsRead` latches
            // them from the two CGS window lists, and that latch hides a window whatever its `spaceIds` say.
            let stillUnplaced = trackedWids.filter { windowToSpacesMap[$0] == nil }
            let placedByWindowServer = Set(WindowServerQuery.query(stillUnplaced)
                .filter { $0.spaceTypeMask != 0 }.map { $0.wid })
            Logger.debug { "spacesSync enumerated=\(snapshot.windowToSpacesMap.count)/\(trackedWids.count) "
                + "perWindowProbe=[\(backfillProbe.joined(separator: " "))] "
                + "unplaced=\(stillUnplaced) wsPlaces=\(placedByWindowServer.sorted())" }
            DispatchQueue.main.async {
                // apply the topology first (the reducer's snapshot must see the fresh Space⇄index map),
                // then the per-window backfill + regroup is the reducer's `.spacesSynced` branch.
                // `queried` is `trackedWids` as captured ABOVE, before the off-main work: windows discovered
                // while this pass ran were never asked about, and the reducer must not read our silence about
                // them as "CGS places them nowhere" (see `.spacesSynced`).
                let topologyChanged = Spaces.applyTopology(snapshot)
                TrackedWindowStateBridge.dispatch(.spacesSynced(windowToSpaces: windowToSpacesMap,
                    queried: Set(trackedWids), placedByWindowServer: placedByWindowServer,
                    topologyChanged: topologyChanged))
            }
        }
    }

    /// Window discovery inventories every WindowServer surface, then acquires AX semantics only for plausible
    /// parentless destinations. Physical rows remain separate from tracked `Window`s, so unresolved native
    /// tabs cannot block inactive-tab adoption.
    static func refreshWindowsViaWindowServer() {
        // the all-Space wid list comes from ONE CGSCopyWindowsWithOptionsAndTags call over every Space
        // (verified to match the per-Space fan-out), not a second windowToSpacesMap rebuild — syncSpacesState
        // owns the per-window membership map; here we only need the wid set.
        let allSpaceIds = Spaces.idsAndIndexes.map { $0.0 }
        guard !allSpaceIds.isEmpty else { return }
        CGSCallScheduler.run {
            let allSpaceWids = CGSCallScheduler.windowsInSpaces(allSpaceIds, true)
            // phantom detection reuses this same all-Space fetch (was a separate per-show CGS double-query
            // that also ran on the AX pool): a wid CGS omits from "visible" but keeps in "all" is alive-but-hidden.
            let visibleWids = Set(CGSCallScheduler.windowsInSpaces(allSpaceIds, false))
            let allWids = Set(allSpaceWids)
            let rawWindows = WindowServerQuery.query(allSpaceWids)
            DispatchQueue.main.async {
                WindowSurfaceInventory.replace(rawWindows)
                Windows.reevaluatePhysicalEvidence(rawWindows)
                // Drain the confirmed-closed tombstones against the two lists we just fetched, BEFORE they
                // gate anything: a wid CGS lists as visible again is genuinely back (a reopened window is
                // untagged, wherever its Space), and a wid CGS finally forgot is gone for good. What's left is
                // exactly the corpse case — closed, yet still lingering in the all-Space list. No clock
                // involved, and no event-driven path is gated: an order-in / focus for the wid reaches
                // `discoverWindow` as it always did.
                widsConfirmedClosed.formIntersection(allWids)
                widsConfirmedClosed.subtract(visibleWids)
                // Same reconcile for the opt-in dedup set: this enumeration is the only place that sees which
                // wids still exist, and destroy events don't erase reliably.
                WindowServerEvents.pruneSubscriptions(allWids)
                var acquisitionRequests = [(raw: WsRawWindow, app: Application, situation: UInt64)]()
                for raw in rawWindows {
                    let physical = PhysicalSurface(raw)
                    guard WindowAdmissionResolver.shouldAcquireSemantics(physical) ||
                            Windows.byWindowId[raw.wid]?.admissionEvidence == .attention else { continue }
                    WindowServerEvents.subscribe(raw.wid)
                    guard let app = findOrCreate(raw.pid, false) else { continue }
                    // tracked windows with a live element stay fresh via the WS event stream
                    // (geometry/min/fullscreen) + reviewExistingWindows (title/tabs); discovery only ACQUIRES
                    // genuinely-new windows.
                    guard Windows.byWindowId[raw.wid]?.axUiElement == nil else { continue }
                    guard !widsConfirmedClosed.contains(raw.wid) else { continue }
                    // A surface that has failed to acquire three times at this app's current window set is
                    // not asked a fourth time. Eligible surfaces are collected here and grouped by pid below,
                    // so one app pays at most one 250ms traversal for the whole inventory pass rather than one
                    // per wid. Event-driven discovery is untouched.
                    let situation = Windows.appWindowSetVersion[raw.pid] ?? 0
                    let previousAttempt = failedAcquisitions[raw.wid]
                    guard SurfaceAcquisitionPolicy.shouldAttempt(recordedSituation: previousAttempt?.situation,
                        attempts: previousAttempt?.attempts ?? 0, situation: situation) else { continue }
                    acquisitionRequests.append((raw, app, situation))
                }
                scheduleSurfaceAcquisitions(acquisitionRequests)
                // Bound the failure table by the same enumeration that gates everything else here: a wid the
                // WindowServer no longer lists can never be swept again, so its record is dead weight.
                failedAcquisitions = failedAcquisitions.filter { allWids.contains($0.key) }
                // regular apps with no windows show as an icon placeholder. It's dropped when a real window
                // arrives (Window.init) or when an existing window un-phantoms (Window.updateSpaces), so a
                // window that recovers its Space after a fullscreen transition clears the stale placeholder
                // instead of leaving both the window tile and the icon tile shown.
                for app in list { _ = app.addWindowlessWindowIfNeeded() }
                // phantom detection reuses this same all-Space fetch; the per-window verdicts + latches are
                // the reducer's `.cgsWindowListsRead` branch
                TrackedWindowStateBridge.dispatch(.cgsWindowListsRead(visible: visibleWids, all: allWids))
            }
        }
    }

    /// One inventory request per PROCESS, because every requested wid is tested by the same AXUIElementID
    /// sequence. The scheduler key also coalesces a newer inventory arriving while this process's traversal is
    /// in flight. Each unresolved wid keeps its own situation-keyed retry record; batching changes cost, not
    /// eligibility or the meaning of a failure.
    private static func scheduleSurfaceAcquisitions(_ requests: [(raw: WsRawWindow, app: Application, situation: UInt64)]) {
        for (pid, batch) in Dictionary(grouping: requests, by: { $0.raw.pid }) {
            guard let app = batch.first?.app else { continue }
            let rows = batch.map { $0.raw }
            AXCallScheduler.shared.schedule(key: "pid-\(pid)-surface-acquire", context: app.debugId, pid: pid, scan: true) {
                let elements = WindowElementAcquisition.elements(for: rows, pid: pid,
                    route: .otherSpaceViaBruteForce)
                DispatchQueue.main.async {
                    for request in batch {
                        guard elements[request.raw.wid] != nil else {
                            // Recorded against the situation the batch was ISSUED at, not the one current
                            // when its shared 250ms traversal finished.
                            noteAcquisitionFailed(request.raw.wid, pid, request.situation)
                            continue
                        }
                        failedAcquisitions[request.raw.wid] = nil
                    }
                }
                for request in batch {
                    guard let element = elements[request.raw.wid] else { continue }
                    addDiscoveredWindow(element, request.raw, request.app)
                }
            }
        }
    }

    /// Acquire and classify a newly-discovered surface. WindowServer-owned facts (geometry, level,
    /// fullscreen) come from the snapshot `raw`; AX is read for what WS can't give cleanly — subrole/role
    /// (admission), title (AX title is preferred), the main flag, minimized (the WS ordered-out bit is
    /// ambiguous — see below), and tab children.
    /// Used for genuinely-new windows only (discovery + discoverWindow). Uses the "generic" bucket so a real
    /// focus event (in the "focus" bucket) is never clobbered.
    /// `adoptedAsInactiveTab`: this window was found by the inactive-tab brute-force (`discoverInactiveTabs`)
    /// — we already KNOW it's a background tab, so the per-window Space query must not be trusted for it: it
    /// returns the STALE old Space for a backgrounded tab (the same lie behind the #5830 burst fix), which
    /// made a cold-start adoption flood arrive as visible "on-screen" windows that the tab matcher was then
    /// forbidden to claim — a switcher full of ghost tiles that only the NEXT show's re-query healed (rec15).
    /// Forced Space-less, it arrives hidden like any unclaimed background tab, and the group converges below.
    static func addDiscoveredWindow(_ element: AXUIElement, _ raw: WsRawWindow, _ app: Application,
                                    adoptedAsInactiveTab: Bool = false) {
        let wid = raw.wid
        AXCallScheduler.shared.schedule(key: "wid-\(wid)-generic", context: app.debugId, pid: app.pid, scan: true) { [weak app] in
            guard let app else { return }
            guard wid != 0 else { return }
            // TilesPanel.shared is nil until the switcher is first built; discovery can now run before that
            // (a window created right at launch), so don't force-unwrap it. If the panel exists and this is
            // its own window, skip it; otherwise it can't be ours, so proceed.
            if let panel = TilesPanel.shared, wid == panel.windowNumber { return }
            let isSelf = app.pid == AXUIElement.currentProcessPid
            // The WS minimized tag is distinct from the ordered-out bit, which is also cleared for closing,
            // app-hidden and other-Space windows.
            let keys = [kAXTitleAttribute, kAXSubroleAttribute, kAXRoleAttribute, kAXMainAttribute] + (isSelf ? [] : [kAXChildrenAttribute])
            let a = try element.attributes(keys, pid: app.pid)
            let semantic = SemanticSurface(title: a.title, subrole: a.subrole, role: a.role, isMain: a.isMain)
            let tabGroup = isSelf ? nil : TabGroup.extractTabGroup(a.children)
            let isFullscreen = WsWindowState.isFullscreen(raw)
            // Both from the SAME WindowServer snapshot this discovery already holds. Minimized used to be an
            // AX `kAXMinimized` read in the batch above; it is a WindowServer tag now, so it cannot be
            // delayed by the app being busy, and one fewer attribute crosses the AX boundary per window.
            let isMinimized = WsWindowState.isMinimized(raw)
            // Resolve the window's REAL Space(s) now, off-main. Window.init defaults spaceIds to the current
            // Space (it runs on main and must avoid this blocking CGS call, #5721); for an other-Space window
            // that default is wrong, and the first post-show syncSpacesState would then correct it → a visible
            // reflow on the first summon (misaligned space numbers / shifted title). Setting it right here makes
            // that later correction a no-op. Skipped for an adopted inactive tab: the query lies for those
            // (stale old Space), and a background tab's true membership is NO Space.
            // A nil answer means the query said nothing at all; treated as empty here, exactly as before,
            // because that is also `Window.init`'s state and the first `syncSpacesState` corroborates it.
            let spaceIds = (isSelf || adoptedAsInactiveTab) ? [CGSSpaceID]()
                : (CGSCallScheduler.windowSpaces(wid) ?? [])
            DispatchQueue.main.async { [weak app] in
                guard let app else { return }
                // discovery always reads tabs (`isSelf` aside), so it teaches `TabReadPolicy` as much as the
                // review pass does — and it is what settles a brand-new app's capability on its first window
                if !isSelf { noteTabRead(wid: wid, pid: app.pid, foundTabGroup: tabGroup != nil) }
                windowAttributesThrottler.throttleOrProceed(key: "\(wid)-generic") {
                    // The shell's job ends at acquisition + raw-fact ingestion: findOrCreate applies the AX/WS
                    // attributes (and appends a genuinely-new window). Everything decided AFTER that — the
                    // pending-removal consume, the MRU promotion, the Space override for background tabs, the
                    // tab-state update, the reconcile — is the reducer's `.discoveryLanded` branch. A surface
                    // not admitted yet still dispatches, so the reducer's pending-removal marker stays self-draining.
                    let findOrCreate = Windows.findOrCreate(element, raw, app, semantic, isFullscreen, isMinimized)
                    // not logged here: the reducer's `.discoveryLanded` line names this window with the facts
                    // that actually matter (tab titles, group, Spaces, whether it was adopted as a tab)
                    findOrCreate.0?.isMainWindow = a.isMain ?? false
                    TrackedWindowStateBridge.dispatch(.discoveryLanded(wid: wid, accepted: findOrCreate.0 != nil,
                        newlyTracked: findOrCreate.1, adoptedAsInactiveTab: adoptedAsInactiveTab,
                        queriedSpaceIds: spaceIds, isOrderedIn: WsWindowState.isVisible(raw),
                        tabTitles: tabGroup?.titles, tabGroupToken: tabGroup?.token))
                    // A genuinely new window changes what the startup guess has to rank, so re-make it here
                    // rather than once on a timer that fires before discovery lands.
                    if findOrCreate.1 { Windows.reseedZOrderDuringStartup() }
                }
            }
        }
    }

    /// WindowServer-driven per-window state refresh (geometry + fullscreen), replacing the AX attribute read
    /// on move/resize/visibility events and the Space-change fullscreen re-read. ONE batched WS query for the
    /// whole wid set (off-main: ~84µs for a full screen vs ~15µs × N serial), decoded by WsWindowState,
    /// applied on main in a single UI reconcile. Minimized IS read here (`WsWindowState.minimizedTag`) —
    /// the ordered-out BIT cannot tell minimized from closing/other-Space, but the tag can, and unlike the AX
    /// read it replaced it cannot be delayed by the window's own app. Callers coalesce upstream where the
    /// input self-floods: the per-event path
    /// throttles per-wid (windowAttributesThrottler, ≤1 query/200ms on a resize drag); the Space-change path
    /// calls this once per transition. `TrackedWindowStateBridge.queueWindowServerStateQuery` batches the
    /// event-driven callers into one query per runloop turn on top of that.
    ///
    /// **Answers are matched to the query that asked for them.** `CGSCallScheduler` is a 4-wide concurrent
    /// lane with no per-key dedup, so two queries naming the same wid can land in either order and the older
    /// one would overwrite the newer window state. `wsStateIssuedSeq` records which query each wid is
    /// currently waiting on; a row whose wid has since been asked about again is dropped, because the newer
    /// answer is on its way and is the one to believe. Main-thread only (all callers are on main).
    private static var wsStateIssueCounter: UInt64 = 0
    private static var wsStateIssuedSeq = [CGWindowID: UInt64]()

    static func updateWindowStatesViaWindowServer(_ wids: [CGWindowID]) {
        guard !wids.isEmpty else { return }
        wsStateIssueCounter += 1
        let seq = wsStateIssueCounter
        for wid in wids { wsStateIssuedSeq[wid] = seq }
        CGSCallScheduler.run {
            let raws = WindowServerQuery.query(wids)
            // decode off-main; the apply (geometry writes, regroup, re-render/re-capture decisions) is the
            // reducer's `.windowServerStateRead` branch
            let decoded = raws.map { raw in
                (raw, WsWindowSnapshot(wid: raw.wid, position: raw.bounds.origin, size: raw.bounds.size,
                    isFullscreen: WsWindowState.isFullscreen(raw), isVisible: WsWindowState.isVisible(raw),
                    isMinimized: WsWindowState.isMinimized(raw)))
            }
            DispatchQueue.main.async {
                // Still the query this wid is waiting on? A newer one has bumped the seq, so this answer is
                // superseded and its replacement is already on its way.
                let fresh = decoded.filter { wsStateIssuedSeq[$0.0.wid] == seq }
                // Then release the wids this query still owned, INCLUDING any the WindowServer returned no
                // row for, or their entries would accumulate for the life of the session. A wid a newer query
                // owns is left alone, so that query can still recognise its own answer.
                for wid in wids where wsStateIssuedSeq[wid] == seq { wsStateIssuedSeq[wid] = nil }
                guard !fresh.isEmpty else { return }
                Windows.reevaluatePhysicalEvidence(fresh.map { $0.0 })
                TrackedWindowStateBridge.dispatch(.windowServerStateRead(fresh.map { $0.1 }))
            }
        }
    }

    /// A tracked window just ordered out (left the screen): it was either CLOSED, or merely minimized / hidden
    /// / moved to another Space. WindowServer can't disambiguate promptly — its destroy event (804) lags a real
    /// close by seconds, or never fires at all, for apps that retain the CGWindow after closing the window
    /// (Finder does). The window's AX element, by contrast, dies within ~20ms of a real close. So probe AX off
    /// -main: a live element means it's just off-screen → leave it. `.cannotComplete` (app busy) throws so the
    /// scheduler retries with backoff instead of wrongly concluding the window closed.
    ///
    /// A dead element (`.invalidUIElement`) is NOT proof of a close on its own: some apps silently rebuild a
    /// window's a11y node, which kills our cached ref while the window lives on (#5586, and the same rebind is
    /// why `Window.focus` retries a raise). So take a second opinion before condemning — ask the app for the
    /// wid again, exactly as discovery would. Measured on macOS 26 (TextEdit): closing a window drops its wid
    /// from `kAXWindows` at once (CGS keeps listing it for seconds), while minimize and app-hide both keep it
    /// there with a still-valid ref. Not found ⇒ really closed ⇒ remove now (prompt, OS-confirmed, NOT
    /// optimistic); found ⇒ our ref was merely stale ⇒ heal it and keep the window.
    ///
    /// Condemning on the weaker test than the one that re-adds the window is what made a live QQ window
    /// disappear and come back seconds later as a "new" window with no MRU history (#5785).
    static func removeIfClosedAfterOrderOut(_ window: Window) {
        guard let axWindow = window.axUiElement, let wid = window.cgWindowId else { return }
        let pid = window.application.pid
        AXCallScheduler.shared.schedule(key: "wid-\(wid)-liveness", pid: pid) {
            let result = axWindow.liveness(pid: pid)
            if result == .cannotComplete { throw AxError.appUnresponsive }
            guard result == .invalidUIElement else {
                Logger.debug { "liveness #\(wid) result=\(result.rawValue) verdict=alive" }
                return
            }
            // Only the cheap `kAXWindows` route: the brute-force one is time-budgeted, so on an app with
            // high AXUIElementIDs it can time out on a window that IS there and hand back the same false
            // "closed" this guard exists to prevent.
            let outcome = WindowElementAcquisition.outcome(for: wid, pid: pid, route: .currentSpaceViaApplicationWindows)
            // Log all three verdicts: a capture where a window vanished needs to show whether this probe ran
            // at all and what it answered.
            Logger.debug { "liveness #\(wid) result=\(result.rawValue) verdict=\(outcome == .absent ? "DEAD" : outcome == .noAnswer ? "noAnswer" : "staleRef")" }
            // The app never answered, so nothing was learned. Throw rather than condemn: the scheduler retries
            // with backoff, and a window whose app is merely busy stays in the switcher. Reading silence as
            // "the app says this window is gone" is what the second opinion exists to prevent.
            guard outcome != .noAnswer else { throw AxError.appUnresponsive }
            DispatchQueue.main.async {
                guard case let .found(fresh) = outcome else {
                    // Remember the verdict, or the inventory sweep re-acquires this very wid a beat later:
                    // CGS keeps listing it and the app can still hand back an element for it (see
                    // `widsConfirmedClosed`).
                    widsConfirmedClosed.insert(wid)
                    TrackedWindowStateBridge.dispatch(.livenessConfirmedDead(wid: wid))
                    return
                }
                Windows.byWindowId[wid]?.rebindAxElement(fresh)
            }
        }
    }

    /// A physical event or exact attention signal named a wid we do not track yet. Discover just that one
    /// window instead of a full inventory; `Window.init` seeds the app's per-process focus fact after append.
    static func discoverWindow(_ wid: CGWindowID) {
        CGSCallScheduler.run {
            guard let raw = WindowServerQuery.query([wid]).first else { return }
            DispatchQueue.main.async {
                WindowSurfaceInventory.upsert([raw])
                if raw.parentWid != 0 {
                    WindowServerEvents.subscribe(raw.parentWid)
                    discoverWindow(raw.parentWid)
                    return
                }
                guard WindowAdmissionResolver.shouldAcquireSemantics(PhysicalSurface(raw)) ||
                        Windows.byWindowId[wid]?.admissionEvidence == .attention else { return }
                // Opt in HERE, not on the raw 811: the physical acquisition verdict is only known once the
                // query above answers, and subscribing before it put every menu, tooltip and Dock indicator
                // on our per-window stream.
                //
                // The cost is a gap: this wid's per-window events are unheard between its create and this
                // line. MEASURED on macOS 26.5, 25 rapid create/destroy cycles with the WindowServer driven
                // to ~99% CPU by 8 window-list hammers — gap p50 7.2ms, p99 12.7ms, and the WindowServer's
                // first per-window event for a brand-new window never arrived before 7.1ms. A/B against a
                // build that subscribed on the 811 instead: same 54 first-events, same 7.0ms floor, same
                // distribution (p50 34ms), same 49 windows accepted. Nothing measurable is lost in the gap.
                // Re-run that A/B before assuming it still holds on a new macOS.
                //
                // It is also survivable by construction: everything discovery needs is read fresh here, and
                // exact attention arriving inside the gap waits for this wid to have a model object before it
                // commits. The per-app discovery seed covers an already-front app at cold start.
                // Deliberately before the guards below — a window AX rejects must stay subscribed (#5785).
                WindowServerEvents.subscribe(wid)
                // A window kept on WindowServer evidence alone must NOT block its own re-acquisition: it is
                // tracked, so the old "already tracked, nothing to do" guard would leave it unverified and
                // unshown for good. Proceed whenever there is no AX element yet.
                guard Windows.byWindowId[wid]?.axUiElement == nil,
                      let app = findOrCreate(raw.pid, false) else { return }
                AXCallScheduler.shared.schedule(key: "wid-\(wid)-acquire", context: app.debugId, pid: raw.pid, scan: true) {
                    guard let element = WindowElementAcquisition.element(for: wid, pid: raw.pid,
                        route: .currentSpaceViaApplicationWindows) else { return }
                    addDiscoveredWindow(element, raw, app)
                }
            }
        }
    }

    // ≤1 inactive-tab brute-force scan per app per 3s, a frequency cap on top of the per-situation budget below.
    static let tabAdoptThrottler = ThrottlerWithKey(delayInMs: 3000)
    // The last unresolved situation (untracked-tab titles + window count) we scanned for, per app, and how many
    // FRUITLESS attempts it has spent. An inactive tab the brute-force can't resolve would otherwise re-fire the
    // scan on every show forever, so each situation gets a small budget (`InactiveTabScanPolicy`), and the app
    // becomes fully eligible again the moment its window set changes (a tab gets adopted, opened, or closed —
    // any of which moves the count or the titles).
    static var lastInactiveTabScan = [pid_t: (situation: String, attempts: Int)]()
    // Where each app's last brute-force sweep stopped. The budget is wall-clock and the AXUIElementID space is
    // UInt64, so one attempt covers a WINDOW of ids, not the space — restarting at 0 made every retry inspect
    // exactly the ids that had already failed, which is why 31 scans in a row adopted nothing while an earlier
    // run (whose windows happened to sit lower) adopted 57. Cleared on a productive scan: the ids around a
    // successful find are the live region, so the next question starts there rather than out in the desert.
    static var inactiveTabScanCursor = [pid_t: AXUIElementID]()

    /// Discover an app's INACTIVE OS TABS. A tabbed window's inactive tabs are real windows, but they appear in
    /// no CGS list, so the WindowServer-driven discovery never sees them — only the focused tab shows until the
    /// user activates another. When an AXTabGroup names tabs we have no window for (`untrackedTitles`), the
    /// inactive tab's accessibility element is still reachable: brute-force the app for the matching untracked
    /// standard windows and adopt them through the normal discovery path. Throttled per app, off-main, bounded.
    ///
    /// The situation and the exclusion set are read INSIDE the throttled block, deliberately. The throttler runs
    /// the leading call now and defers the next one by up to 3s, running the block captured at THAT call — so
    /// values snapshotted out here are up to 3s stale by the time the scan uses them, which meant excluding a
    /// set of tracked wids that no longer matched the model and recording a situation the app had already left.
    /// An attempt should act on, and be recorded against, the facts as they are when it runs.
    static func discoverInactiveTabs(_ app: Application, _ untrackedTitles: [String], _ requesterWid: CGWindowID) {
        let pid = app.pid
        tabAdoptThrottler.throttleOrProceed(key: "\(pid)") {
            let appWindowCount = Windows.list.reduce(0) { $1.application.pid == pid ? $0 + 1 : $0 }
            let situation = "\(untrackedTitles.sorted().joined(separator: "\u{1}"))|\(appWindowCount)"
            let previous = lastInactiveTabScan[pid]
            guard InactiveTabScanPolicy.shouldScan(recordedSituation: previous?.situation,
                                                   attempts: previous?.attempts ?? 0, situation: situation) else { return }
            let trackedWids = Set(Windows.list.compactMap { $0.cgWindowId })
            // ANCHOR the sweep near the app's OWN known elements instead of at id 0 — the decision that
            // actually made this scan work (`InactiveTabScanPolicy.scanStart`). `AXUIElement.id()` reads an
            // element's own id, so a window we already track names the band this app's windows live in.
            let knownIds = Windows.list.filter { $0.application.pid == pid }.compactMap { $0.axUiElement?.id() }
            let startId = InactiveTabScanPolicy.scanStart(cursor: inactiveTabScanCursor[pid],
                                                          lowestKnownId: knownIds.min())
            // Where this app's other windows sit, so a candidate parked on one of them can be recognised
            // as ITS tab rather than the requester's — see `BruteForceWindowMatch.isPlausibleInactiveTab`.
            //
            // **Asked of the WINDOW SERVER, not of `Windows.list`.** The gate can only reject a candidate
            // parked on another of this app's windows if it KNOWS that window, and at launch this scan
            // routinely runs before the app's second window has been tracked: `others=[]` then waves
            // everything through, and the tabs of a window we had not seen yet were adopted as the
            // requester's. Two real windows ended up in ONE tab group, the second hidden inside it as a
            // non-representative member and no longer offered at all (live 2026-08-25 — the scan logged
            // `requester=#52149@(80,600) others=[]` and then adopted two tabs sitting at (80,80)).
            //
            // Read from the sweep's own inventory rather than re-asking the OS. The rows are the same
            // decoder's output, so the frames stay in one coordinate space, and after a full sweep the
            // inventory is a SUPERSET of the on-screen list (every app-level surface on every Space). That
            // retires a system-wide `CGWindowListCopyWindowInfo` plus a second batched `SLSWindowQueryWindows`
            // over everything it returned — two heavy calls per scan, and cold start fires one per tabbed app.
            // `visibleSurfaces` answers nil before the first sweep, which is the only state where the
            // inventory could hand back the short list that made `others=[]` dangerous; there we pay for the
            // live call exactly as before.
            let surfaces = WindowSurfaceInventory.visibleSurfaces(pid: pid)
            let frames = surfaces.map { rows -> (CGRect?, [CGRect]) in
                // the requester may be off-screen mid-transition, so it is looked up in the whole inventory
                let requester = WindowSurfaceInventory.raw(requesterWid).map { CGRect(origin: $0.bounds.origin, size: .zero) }
                return (requester, rows.filter { $0.wid != requesterWid }.map { CGRect(origin: $0.bounds.origin, size: .zero) })
            }
            AXCallScheduler.shared.schedule(key: "pid-\(pid)-tabadopt", context: app.debugId, pid: pid, scan: true) { [weak app] in
                guard let app else { return }
                let (requesterFrame, otherFrames) = frames ?? {
                    let onScreen = WindowServerQuery.query(CGWindow.windows(.optionOnScreenOnly).compactMap { $0.id() })
                    return (onScreen.first { $0.wid == requesterWid }.map { CGRect(origin: $0.bounds.origin, size: .zero) },
                            onScreen.filter { $0.pid == pid && $0.wid != requesterWid && WsWindowState.isVisible($0) }
                                .map { CGRect(origin: $0.bounds.origin, size: .zero) })
                }()
                // `isPlausibleInactiveTab` waves everything through when the requester has no frame or the app
                // has no other windows, so both inputs are logged: without them a green run cannot be told
                // apart from a gate that is wired up but inert.
                Logger.debug { "inactive-tab scan pid:\(pid) knownIds=\(knownIds.sorted().prefix(6)) from=\(startId) requester=#\(requesterWid)@\(requesterFrame?.origin.debugDescription ?? "nil") others=\(otherFrames.map { $0.origin })" }
                let (found, nextId) = AXUIElement.untrackedWindowsByBruteForce(
                    pid, excluding: trackedWids, matching: untrackedTitles, from: startId)
                var adopted = 0
                // The lowest id this sweep found and handed back because it belongs to ANOTHER window of
                // this app. It is a find for that window's own sweep, so the cursor must not step over it
                // (`InactiveTabScanPolicy.nextCursor`).
                var deferredId: AXUIElementID?
                for (wid, element, title) in found {
                    guard let raw = WindowServerQuery.query([wid]).first else {
                        Logger.debug { "inactive tab wid:\(wid) '\(title)' has no WindowServer data; skipping" }
                        continue
                    }
                    // An inactive tab is BEHIND the active one, so the WindowServer does not have it on
                    // screen. A candidate it does have on screen is a window in its own right that merely
                    // shares a title with one of this app's tabs — which is not rare at all, because the
                    // titles we match on are tab titles, and two Finder windows browsing the same folder
                    // both have a tab called "lwouis". Adopting one swallowed a real, visible, FOCUSED
                    // window into another window's group: it stopped being drawn (a non-representative
                    // member is hidden), so the switcher silently lost a window and the default pick
                    // landed one tile past where the user was aiming.
                    //
                    // Title matching cannot tell the two apart (#5785: tab titles are not window titles,
                    // and no reliable tab->window mapping exists), so the on-screen bit is what separates
                    // them. A missed adoption is cheap — the next scan retries — while a wrong one hides a
                    // window the user is looking at.
                    guard !WsWindowState.isVisible(raw) else {
                        Logger.debug { "inactive tab candidate wid:\(wid) '\(title)' is ON SCREEN, so it is a window of its own, not a tab of this one; skipping" }
                        continue
                    }
                    guard BruteForceWindowMatch.isPlausibleInactiveTab(
                        candidate: raw.bounds, requester: requesterFrame, otherWindowsOfApp: otherFrames) else {
                        if let elementId = element.id() { deferredId = min(deferredId ?? elementId, elementId) }
                        Logger.debug { "inactive tab candidate wid:\(wid) '\(title)' sits at \(raw.bounds.origin), on another window of this app rather than on #\(requesterWid); it is that window's tab, deferring it to that window's own scan" }
                        continue
                    }
                    Logger.debug { "discovered inactive tab via brute-force: wid:\(wid) '\(title)' at \(raw.bounds.origin) for #\(requesterWid)" }
                    adopted += 1
                    addDiscoveredWindow(element, raw, app, adoptedAsInactiveTab: true)
                }
                // Record the OUTCOME, not the intent: a fruitless attempt spends one of the situation's budget,
                // a productive one spends none. Recording before the scan is what gave up forever on a single
                // transient miss (the app's AX tree not ready yet at launch).
                let attempts = InactiveTabScanPolicy.attemptsAfterScan(previousAttempts: previous?.attempts ?? 0,
                    sameSituation: previous?.situation == situation, adopted: adopted)
                let cursor = InactiveTabScanPolicy.nextCursor(adopted: adopted, deferredId: deferredId, sweptTo: nextId)
                if adopted == 0 {
                    Logger.debug { "inactive-tab scan found nothing (attempt \(attempts)/\(InactiveTabScanPolicy.maxAttemptsPerSituation), ids \(startId)..<\(nextId), resuming at \(cursor))" }
                }
                DispatchQueue.main.async {
                    lastInactiveTabScan[pid] = (situation, attempts)
                    inactiveTabScanCursor[pid] = cursor
                }
            }
        }
    }

    /// Light per-window AX read for already-tracked windows: the facts the WindowServer genuinely cannot
    /// deliver — title (no WS title-change event), the main-window flag, and tab siblings. Minimized is NOT
    /// among them any more: it is `WsWindowState.minimizedTag`, read from the WS query instead.
    /// Shares the "wid-N-generic" dedup/throttle key so it never double-reads a window the discovery pass
    /// just refreshed. Runs for every tracked window on each show.
    static func refreshWindowTitleAndTabs(_ axWindow: AXUIElement, _ wid: CGWindowID, _ app: Application, _ reconcileTabs: Bool = true) {
        // Snapshotted HERE, on main, at issue time. Recording the version the answer lands against instead
        // would mark a window up to date with a window set that changed while its read was in flight.
        let appWindowSetVersionAtRead = Windows.appWindowSetVersion[app.pid] ?? 0
        // A read with no tabs to reconcile exists ONLY to refresh the title, and an app whose observer holds
        // a live `AXTitleChanged` subscription has already pushed it (`applyObservedTitle`). So this is the
        // whole call skipped, not a shortened one: order-in and order-out fire on every minimize, every
        // Space move and every raise, which made them the most frequent AX calls the app issued.
        // The per-show pass (`reviewExistingWindows`, `reconcileTabs: true`) deliberately still reads the
        // title: it is the backstop for a notification that never arrived, and it is paying for the
        // kAXChildren round trip anyway. Nothing waits on the `.titleAndTabsRead` this skips — it would
        // reconcile no tabs and report no change.
        guard reconcileTabs || !AxObserverRegistry.deliversTitles(app.pid) else { return }
        AXCallScheduler.shared.schedule(key: "wid-\(wid)-generic", context: app.debugId, pid: app.pid, scan: true) { [weak app] in
            guard let app else { return }
            guard wid != 0 else { return }
            // TilesPanel.shared is nil until the switcher is first built; discovery can now run before that
            // (a window created right at launch), so don't force-unwrap it. If the panel exists and this is
            // its own window, skip it; otherwise it can't be ours, so proceed.
            if let panel = TilesPanel.shared, wid == panel.windowNumber { return }
            let isSelf = app.pid == AXUIElement.currentProcessPid
            // Skip the tab-group read when the caller says not to reconcile tabs (an order-out): an
            // ordered-out window reports its AXTabGroup inconsistently mid-transition, and order-out never
            // changes tab membership anyway. Saves the kAXChildren IPC too.
            let readTabs = !isSelf && reconcileTabs
            let keys = [kAXTitleAttribute, kAXSubroleAttribute, kAXRoleAttribute, kAXMainAttribute] +
                (readTabs ? [kAXChildrenAttribute] : [])
            let a = try axWindow.attributes(keys, pid: app.pid)
            let tabGroup = readTabs ? TabGroup.extractTabGroup(a.children) : nil
            DispatchQueue.main.async {
                // Recorded outside the throttle: this read HAPPENED, and "no tab group" is as much of an
                // answer as a group. Inside, a coalesced call would leave the window looking never-read and
                // `TabReadPolicy` would keep re-electing it.
                if readTabs {
                    noteTabRead(wid: wid, pid: app.pid, foundTabGroup: tabGroup != nil,
                        appWindowSetVersion: appWindowSetVersionAtRead)
                }
                windowAttributesThrottler.throttleOrProceed(key: "\(wid)-generic") {
                    guard let window = Windows.byWindowId[wid] else { return }
                    // raw-fact ingestion stays here (bestEffortTitle needs the CG-title fallback IPC); the
                    // tab reconcile + re-render decision is the reducer's `.titleAndTabsRead` branch
                    let newTitle = window.bestEffortTitle(a.title)
                    let semantic = SemanticSurface(title: newTitle, subrole: a.subrole, role: a.role, isMain: a.isMain)
                    guard Windows.reevaluateAdmission(window, semantic) else { return }
                    let changed = window.title != newTitle
                    if changed { window.title = newTitle; window.lastSearchQuery = nil }
                    window.isMainWindow = a.isMain ?? false
                    TrackedWindowStateBridge.dispatch(.titleAndTabsRead(wid: wid, tabTitles: tabGroup?.titles,
                        tabGroupToken: tabGroup?.token, reconcileTabs: reconcileTabs, changedSoFar: changed))
                }
            }
        }
    }

    /// A title an app PUSHED through its own AX observer (`AxObserverRegistry.refreshTitle`), applied on the
    /// same path a read would take. Before this, `kAXTitleChanged` had no equivalent anywhere in the app and
    /// the title was only as fresh as the last order event or switcher show — the staleness `matchSiblings`
    /// sees when it compares fresh AX tab titles against model window titles.
    ///
    /// Throttled per wid on its own key (not the shared "generic" one, or a discovery in flight would
    /// swallow it): the title is the one fact whose update RATE the observed app chooses, and a window
    /// tracking a build log or a progress bar renames itself continuously.
    static func applyObservedTitle(wid: CGWindowID, title: String?) {
        windowAttributesThrottler.throttleOrProceed(key: "\(wid)-title") {
            guard let window = Windows.byWindowId[wid] else { return }
            let newTitle = window.bestEffortTitle(title)
            guard window.title != newTitle else { return }
            window.title = newTitle
            window.lastSearchQuery = nil
            TrackedWindowStateBridge.dispatch(.titleAndTabsRead(wid: wid, tabTitles: nil,
                tabGroupToken: nil, reconcileTabs: false, changedSoFar: true))
        }
    }

    /// Whether each app has ever exposed an `AXTabGroup`, and when each window's tabs were last read against
    /// which version of its app's window set. `TabReadPolicy` turns the three into a per-show verdict; see
    /// its Specs for why the blanket per-show read was the wrong size.
    private static var appSawTabGroup = [pid_t: Bool]()
    private static var lastTabRead = [CGWindowID: (generation: UInt64, appWindowSetVersion: UInt64)]()
    private static var tabReadGeneration: UInt64 = 0

    static func forgetTabRead(_ wid: CGWindowID) {
        lastTabRead[wid] = nil
    }

    /// Record what a completed tab read learned. Called for every read that actually looked for tabs, so a
    /// window that answers "no tab group" is as much of an answer as one that answers with tabs.
    static func noteTabRead(wid: CGWindowID, pid: pid_t, foundTabGroup: Bool, appWindowSetVersion: UInt64? = nil) {
        // sticky: an app that has shown a tab group once is a tabbing app even while its current windows
        // happen to have no tabs open
        appSawTabGroup[pid] = (appSawTabGroup[pid] ?? false) || foundTabGroup
        tabReadGeneration &+= 1
        lastTabRead[wid] = (tabReadGeneration, appWindowSetVersion ?? Windows.appWindowSetVersion[pid] ?? 0)
    }

    private static func tabCapability(_ pid: pid_t) -> AppTabCapability {
        guard let saw = appSawTabGroup[pid] else { return .unknown }
        return saw ? .seenTabGroup : .neverSeenTabGroup
    }

    /// Re-read the AX-only facts WindowServer can't deliver, for all tracked windows, in case events were
    /// incomplete: title, the main-window flag, and tab siblings. Geometry/fullscreen/minimized are
    /// WindowServer-maintained (806/807 + the tags), so those are NOT re-read or overwritten here.
    ///
    /// The TAB half is no longer asked of every window every time — `TabReadPolicy` picks the few that owe an
    /// answer. The title half still runs for every window, and is itself skipped inside
    /// `refreshWindowTitleAndTabs` for any app whose observer pushes titles, so a window this pass skips
    /// costs one round trip or none.
    static func reviewExistingWindows() {
        var reviewable = [(Window, CGWindowID, AXUIElement)]()
        for window in Windows.list {
            guard !window.isWindowlessApp, let wid = window.cgWindowId, let axUiElement = window.axUiElement
                else { continue }
            reviewable.append((window, wid, axUiElement))
        }
        let candidates = reviewable.map { window, wid, _ -> TabReadCandidate in
            let pid = window.application.pid
            let last = lastTabRead[wid]
            return TabReadCandidate(wid: wid, capability: tabCapability(pid),
                appWindowsChangedSinceLastRead: last?.appWindowSetVersion != Windows.appWindowSetVersion[pid] ?? 0,
                lastReadGeneration: last?.generation)
        }
        let readTabsFor = TabReadPolicy.windowsToRead(candidates)
        Logger.debug { "reviewExistingWindows windows=\(reviewable.count) tabReads=\(readTabsFor.count)" }
        for (window, wid, axUiElement) in reviewable {
            refreshWindowTitleAndTabs(axUiElement, wid, window.application, readTabsFor.contains(wid))
        }
    }

    static func addRunningApplications(_ runningApps: [NSRunningApplication], _ needToVerifyFrontmostPid: Bool) {
        runningApps.forEach { runningApp in
            let bundleIdentifier = runningApp.bundleIdentifier
            let processIdentifier = runningApp.processIdentifier
            if bundleIdentifier == "com.apple.dock" {
                DockEvents.observe(processIdentifier)
            }
            // com.apple.universalcontrol always fails subscribeToNotification. We blacklist it to save resources on everyone's machines
            guard bundleIdentifier != "com.apple.universalcontrol" else { return }
            // classify off-main (process & sysctl IPC), then create on main if it's a real app (#5721).
            // findOrCreate stays synchronous for the rarer AX-event new-pid path (it re-checks the list).
            // `thenMain`, so the verdict is recorded on the thread that owns the table.
            ProcessCallScheduler.isActualApplication(processIdentifier, bundleIdentifier) { isActual in
                guard isActual else {
                    refusedByDiscovery[processIdentifier] = RefusedApplication(bundleId: bundleIdentifier)
                    return
                }
                refusedByDiscovery[processIdentifier] = nil
                createActualApp(runningApp)
            }
        }
    }

    // The post-classification half of findOrCreate, for the discovery path where classification already
    // ran off-main via ProcessCallScheduler. Runs on main; dedups by pid so it can't race a parallel creation.
    private static func createActualApp(_ runningApp: NSRunningApplication) {
        let pid = runningApp.processIdentifier
        guard !(list.contains { $0.pid == pid }) else { return }
        list.append(Application(runningApp))
    }

    static func removeRunningApplications(_ terminatingApps: [NSRunningApplication]) {
        let existingAppsToRemove = list.filter { app in terminatingApps.contains { tApp in app.runningApplication.isEqual(tApp) } }
        let existingWindowstoRemove = Windows.list.filter { window in terminatingApps.contains { tApp in window.application.runningApplication.isEqual(tApp) } }
        if existingAppsToRemove.isEmpty && existingWindowstoRemove.isEmpty { return }
        for tApp in terminatingApps {
            let ofQuitApp = Windows.list.filter { $0.application.runningApplication.isEqual(tApp) }
            if !ofQuitApp.isEmpty { Logger.debug { "remove appQuit count=\(ofQuitApp.count) \(ofQuitApp.map { $0.debugId })" } }
            Windows.removeWindows(ofQuitApp, false)
            // comparing pid here can fail here, as it can be already nil; we use isEqual here to avoid the issue
            list.removeAll { $0.runningApplication.isEqual(tApp) }
        }
        for tApp in terminatingApps {
            let pid = tApp.processIdentifier
            WindowSurfaceInventory.remove(pid: pid)
            AxObserverRegistry.shared.processExited(pid, generation: AttentionEngine.generation(of: pid))
            AttentionEngine.processExited(pid)
            AXCallScheduler.shared.removeEntry(key: "pid-\(pid)")
            AXCallScheduler.shared.removeEntries(withPrefix: "pid-\(pid)-")
            AXCallScheduler.shared.removeUnresponsivePid(pid)
            appSawTabGroup[pid] = nil
            lastInactiveTabScan[pid] = nil
            inactiveTabScanCursor[pid] = nil
            Windows.forgetAppWindowSetVersion(pid)
            refusedByDiscovery[pid] = nil
            ApplicationDiscriminator.forgetProcess(pid)
            failedAcquisitions = failedAcquisitions.filter { $0.value.pid != pid }
        }
        App.refreshOpenUiAfterExternalEvent([])
    }

    static func refreshBadgesAsync() {
        guard SwitcherSession.isActive else { return }
        dockBadgeThrottler.throttleOrProceed {
            let dockPid = list.first { $0.bundleIdentifier == "com.apple.dock" }?.pid
            AXCallScheduler.shared.schedule(key: "badges", context: "badges", pid: dockPid) {
                guard let dockPid,
                    let axDockChildren = try AXUIElementCreateApplication(dockPid).attributes([kAXChildrenAttribute]).children,
                    let axListAttrs = (axDockChildren.lazy.compactMap { try? $0.attributes([kAXRoleAttribute, kAXChildrenAttribute]) }.first { $0.role == kAXListRole }),
                    let axListChildren = axListAttrs.children else { return }
                // `try?` per item, deliberately: one Dock tile that fails to answer skips itself rather than
                // aborting the whole badge refresh.
                let axAppDockItemUrlAndLabel: [(URL?, String?)] = axListChildren.compactMap {
                    guard let a = try? $0.attributes([kAXSubroleAttribute, kAXIsApplicationRunningAttribute, kAXURLAttribute, kAXStatusLabelAttribute]),
                          a.subrole == kAXApplicationDockItemSubrole, a.appIsRunning ?? false else { return nil }
                    return (a.url, a.statusLabel)
                }
                guard !axAppDockItemUrlAndLabel.isEmpty else { return }
                DispatchQueue.main.async {
                    guard SwitcherSession.isActive else { return }
                    refreshBadges_(axAppDockItemUrlAndLabel)
                }
            }
        }
    }

    static func refreshBadges_(_ items: [(URL?, String?)]) {
        Windows.list.enumerated().forEach { (i, window) in
            let view = TilesView.recycledViews[i]
            if let app = findOrCreate(window.application.pid, false) {
                if app.activationPolicy == .regular,
                   let matchingItem = (items.first { $0.0 == app.bundleURL }),
                   let label = matchingItem.1 {
                    app.dockLabel = label
                    view.updateDockLabelIcon(label)
                } else {
                    app.dockLabel = nil
                    assignIfDifferent(&view.dockLabelIcon.isHidden, true)
                }
            }
        }
    }

    @discardableResult
    static func findOrCreate(_ pid: pid_t, _ needToVerifyFrontmostPid: Bool,
                             evidence: ApplicationAdmissionEvidence = .discovery) -> Application? {
        if let app = (list.first { $0.pid == pid }) { return app }
        // A WindowServer row can name pid 0 (no owner). Asking LaunchServices about it fails 1,078 times a
        // pass and can never do anything else.
        guard pid > 0 else { return nil }
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            Logger.debug { "NSRunningApplication init failed for pid:\(pid)" }
            return nil
        }
        // Asked with the bundle id in hand, so a reused pid misses and is classified properly. The lookup
        // above is a LaunchServices read AppKit already caches; what the refusal saves is the process and
        // sysctl IPC below.
        guard !ApplicationVerdictCache.refusalStillAnswers(refusedByDiscovery[pid],
                  bundleId: runningApp.bundleIdentifier, evidence: evidence) else { return nil }
        guard ApplicationDiscriminator.isActualApplication(pid, runningApp.bundleIdentifier, evidence: evidence) else {
            if evidence == .discovery {
                refusedByDiscovery[pid] = RefusedApplication(bundleId: runningApp.bundleIdentifier)
            }
            return nil
        }
        refusedByDiscovery[pid] = nil
        let app = Application(runningApp)
        list.append(app)
        return app
    }

    static func updateAppIcons() {
        for app in list {
            BackgroundWork.screenshotsQueue.addOperation { [weak app] in
                guard let app else { return }
                let r = Application.appIconWithoutPadding(app.runningApplication.icon)
                DispatchQueue.main.async { [weak app] in
                    app?.icon = r?.image
                    app?.iconSourcePixels = r?.sourcePixels
                }
            }
        }
    }
}
