class WindowDiscriminator {
    static func isActualWindow(_ app: Application, _ wid: CGWindowID, _ level: CGWindowLevel, _ title: String?, _ subrole: String?, _ role: String?, _ size: CGSize?, _ isMain: Bool?) -> Bool {
        // Some non-windows have title: nil (e.g. some OS elements)
        // Some non-windows have subrole: nil (e.g. some OS elements), "AXUnknown" (e.g. Bartender), "AXSystemDialog" (e.g. Intellij tooltips)
        // Minimized windows or windows of a hidden app have subrole "AXDialog"
        // Activity Monitor main window subrole is "AXDialog" for a brief moment at launch; it then becomes "AXStandardWindow"
        // Some non-windows have cgWindowId == 0 (e.g. windows of apps starting at login with the checkbox "Hidden" checked)
        guard wid != 0 else {
            Logger.debug { logTemplate("wid is 0", app, wid, level, title, subrole, role, size, isMain) }
            return false
        }
        guard let size else {
            Logger.debug { logTemplate("it has no size", app, wid, level, title, subrole, role, size, isMain) }
            return false
        }
        guard size.width > 100 && size.height > 50 else {
            Logger.debug { logTemplate("size is \(Int(size.width))x\(Int(size.height)) which is < 100x50", app, wid, level, title, subrole, role, size, isMain) }
            return false
        }
        // ordered cheapest-first so `||`/`&&` short-circuit; nothing below is computed unless needed.
        // a standard subrole (the overwhelmingly common case) accepts before any per-app work; isMainWindow is
        // two free comparisons on facts already in hand; the per-app chains — string compares plus a
        // KERN_PROCARGS sysctl for bundle-id-less apps (androidEmulator) — run only for the rare non-standard
        // window that neither of the first two arms took. isSpecialApp is re-checked below but only reaches
        // that line on the rare accepted-non-standard path; the common case evaluates it at most once.
        // Only the ACCEPT gate is widened here: an isMain window still faces the mustHave* reject gate below,
        // so the per-app reject rules (Steam, JetBrains, ColorSlurp, androidEmulator...) still bite.
        guard isStandardSubrole(subrole) || isMainWindow(role, isMain) || isSpecialApp(app, title, subrole, role, level) || appSpecificSubrole(app, title, role, subrole, size) else {
            Logger.debug { logTemplate("subrole is '\(subrole ?? "nil")' instead of '\(kAXStandardWindowSubrole)'/'\(kAXDialogSubrole)'", app, wid, level, title, subrole, role, size, isMain) }
            return false
        }
        if !isSpecialApp(app, title, subrole, role, level) {
            guard mustHaveIfJetbrainApp(app, title, subrole, size) &&
                mustHaveIfSteam(app, title, role) &&
                mustHaveIfFusion360(app, title, role) &&
                mustHaveIfColorSlurp(app, subrole) &&
                mustHaveIfAndroidEmulator(app, title) else {
                Logger.debug { logTemplate("of a hardcoded rule for this app", app, wid, level, title, subrole, role, size, isMain) }
                return false
            }
        }
        Logger.debug { logTemplate(nil, app, wid, level, title, subrole, role, size, isMain) }
        return true
    }

    private static func logTemplate(_ rejectionReason: String?, _ app: Application, _ wid: CGWindowID, _ level: CGWindowLevel, _ title: String?, _ subrole: String?, _ role: String?, _ size: CGSize?, _ isMain: Bool?) -> String {
        "Window \(rejectionReason == nil ? "accepted" : "rejected") \(app.debugId)\(rejectionReason == nil ? "" : " because \(rejectionReason)") \((wid, level, title, subrole, role, size, isMain))"
    }

    /// First, cheap gate on the raw WindowServer snapshot, before an AX element is even acquired:
    /// only level-0 application windows are switch candidates (the menu bar, Control Center, the
    /// Dock, wallpaper, tooltips and menus sit at other levels). Coarse — it can't tell
    /// AXStandardWindow from AXDialog/AXUnknown — so a window accepted here still goes through
    /// `isActualWindow` once its AX element is read.
    static func isApplicationWindow(_ raw: WsRawWindow) -> Bool {
        guard WsWindowState.isApplicationWindowLevel(raw) else {
            Logger.debug { "Window rejected (pid:\(raw.pid) wid:\(raw.wid)) because its level \(raw.level) is not an application window level (title:\(raw.title))" }
            return false
        }
        return true
    }

    /// Acquire the AX element for a WindowServer-discovered wid, rejecting (with a log) when AX can't resolve
    /// it to a live window: the wid isn't in the app's `kAXWindows` on its Space and no brute-force token
    /// matched. That's a window CGS still lists but AX no longer backs — a transient that never ordered in
    /// (Joplin), or a window torn down between the snapshot and this read. Off-main (AX IPC), like the
    /// underlying `WindowElementAcquisition`.
    static func acquireElementOrReject(_ wid: CGWindowID, _ pid: pid_t, _ route: WindowAcquisitionPolicy.Route) -> AXUIElement? {
        guard let element = WindowElementAcquisition.element(for: wid, pid: pid, route: route) else {
            Logger.debug { "Window rejected (pid:\(pid) wid:\(wid)) because no live AX window element could be acquired for it" }
            return nil
        }
        return element
    }

    /// The generic form of the presentation-mode whitelists (Keynote, PowerPoint): an app that means "this
    /// IS the document now" makes its window main, and AppKit only grants that to a window whose
    /// `canBecomeMainWindow` says yes — which `NSPanel` and borderless windows decline by default. Measured
    /// against the shapes the subrole gate exists to exclude (floating utility panel, borderless tooltip,
    /// keyable borderless HUD): all reported main=0, while PowerPoint's slide show reported main=1.
    ///
    /// Deliberately NOT `kAXFocusedWindow`, which named two of those three false positives: it answers for
    /// EVERY app (front or not), so it would exempt one window per running app, and a keyable HUD is focusable.
    /// Only one window per app can be main, so at most one non-standard window per app gets in here.
    ///
    /// This is a CONVENTION, not a guarantee. `kAXMain`'s value is `NSWindow.isMainWindow` and its settability
    /// is `canBecomeMainWindow` (measured 8/8) — which AppKit defaults to NO for borderless windows and every
    /// NSPanel, but which an app can flip with a one-line override. A borderless AXUnknown window and a
    /// floating NSPanel were both made main that way in a test app. Swept ~100 real apps and the convention
    /// held: only PowerPoint's slide show and the Paddle licensing SDK's trial dialog (an app's only window,
    /// in both cases) ever reported main on a non-standard subrole. Note that an accepted window is never
    /// re-discriminated, so an admission here is permanent.
    ///
    /// No level condition: the inventory path already filters to `isApplicationWindowLevel` (level 0). The
    /// role check is a cheap guard, not a proven one: `kAXWindows` can hand back non-window elements (Finder's
    /// desktop arrives as an `AXScrollArea`), but across 62 windows of 53 apps nothing ever reported main on a
    /// non-`AXWindow` role, and that Finder case dies on the `wid == 0` guard above anyway. It pins the
    /// predicate to "a main WINDOW" for two free comparisons; it is not carrying a known case.
    private static func isMainWindow(_ role: String?, _ isMain: Bool?) -> Bool {
        return isMain == true && role == kAXWindowRole
    }

    private static func isStandardSubrole(_ subrole: String?) -> Bool {
        return [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole)
    }

    private static func isSpecialApp(_ app: Application, _ title: String?, _ subrole: String?, _ role: String?, _ level: CGWindowLevel) -> Bool {
        return books(app) || keynote(app) || preview(app, subrole) || iina(app) ||
            openFlStudio(app, title) || crossoverWindow(app, role, subrole, level) ||
            isAlwaysOnTopScrcpy(app, level, role, subrole)
    }

    private static func appSpecificSubrole(_ app: Application, _ title: String?, _ role: String?, _ subrole: String?, _ size: CGSize?) -> Bool {
        return openBoard(app) || adobeAudition(app, subrole) || adobeAfterEffects(app, subrole) ||
            adobePremierePro(app, subrole) ||
            steam(app, title, role) || worldOfWarcraft(app, role) || battleNetBootstrapper(app, role) ||
            firefox(app, role, size) || vlcFullscreenVideo(app, role) || sanGuoShaAirWD(app) ||
            dvdFab(app) || drBetotte(app) || androidEmulator(app, title) || autocad(app, subrole) ||
            powerpoint(app, role)
    }

    private static func powerpoint(_ app: Application, _ role: String?) -> Bool {
        // PowerPoint's slide show covers the screen with an AXUnknown window at level 0 instead of using
        // standard fullscreen mode, same as Keynote's presentation mode. The role gate keeps the app's
        // non-window AXUnknown elements out. Note the lowercase "point" in the bundle id (#5983)
        return app.bundleIdentifier == "com.microsoft.Powerpoint" && role == kAXWindowRole
    }

    private static func mustHaveIfFusion360(_ app: Application, _ title: String?, _ role: String?) -> Bool {
        // filter out Autodesk Fusion side panels "Browser" and "Comments" with subrole AXDialog but with no title
        return app.bundleIdentifier != "com.autodesk.fusion360" || (title != nil && title != "")
    }

    private static func mustHaveIfJetbrainApp(_ app: Application, _ title: String?, _ subrole: String?, _ size: NSSize) -> Bool {
        // jetbrain apps sometimes generate non-windows that pass all checks in isActualWindow
        // they have no title, so we can filter them out based on that
        // we also hide windows too small
        return app.bundleIdentifier?.range(of: "^com\\.(jetbrains\\.|google\\.android\\.studio).*?$", options: .regularExpression) == nil || (
            (subrole == kAXStandardWindowSubrole || (title != nil && title != "")) &&
                size.width > 100 && size.height > 100
        )
    }

    private static func mustHaveIfColorSlurp(_ app: Application, _ subrole: String?) -> Bool {
        return app.bundleIdentifier != "com.IdeaPunch.ColorSlurp" || subrole == kAXStandardWindowSubrole
    }

    private static func iina(_ app: Application) -> Bool {
        // IINA.app can have videos float (level == 2 instead of 0)
        // there is also complex animations during which we may or may not consider the window not a window
        return app.bundleIdentifier == "com.colliderli.iina"
    }

    private static func keynote(_ app: Application) -> Bool {
        // apple Keynote has a fake fullscreen window when in presentation mode
        // it covers the screen with a AXUnknown window instead of using standard fullscreen mode
        return app.bundleIdentifier == "com.apple.iWork.Keynote"
    }

    private static func preview(_ app: Application, _ subrole: String?) -> Bool {
        // when opening multiple documents at once with apple Preview,
        // one of the window will have level == 1 for some reason
        return app.bundleIdentifier == "com.apple.Preview" && [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole)
    }

    private static func openFlStudio(_ app: Application, _ title: String?) -> Bool {
        // OpenBoard is a ported app which doesn't use standard macOS windows
        return app.bundleIdentifier == "com.image-line.flstudio" && (title != nil && title != "")
    }

    private static func openBoard(_ app: Application) -> Bool {
        // OpenBoard is a ported app which doesn't use standard macOS windows
        return app.bundleIdentifier == "org.oe-f.OpenBoard"
    }

    private static func adobeAudition(_ app: Application, _ subrole: String?) -> Bool {
        // recent Adobe bundle ids gained a version/".application" suffix, so we match by prefix
        return (app.bundleIdentifier?.hasPrefix("com.adobe.Audition") ?? false) && subrole == kAXFloatingWindowSubrole
    }

    private static func adobeAfterEffects(_ app: Application, _ subrole: String?) -> Bool {
        // AE 2026's bundle id became "com.adobe.AfterEffects.application" (was "com.adobe.AfterEffects"); match by prefix
        return (app.bundleIdentifier?.hasPrefix("com.adobe.AfterEffects") ?? false) && subrole == kAXFloatingWindowSubrole
    }

    private static func adobePremierePro(_ app: Application, _ subrole: String?) -> Bool {
        return (app.bundleIdentifier?.hasPrefix("com.adobe.PremierePro") ?? false) && subrole == kAXFloatingWindowSubrole
    }

    private static func books(_ app: Application) -> Bool {
        // Books.app has animations on window creation. This means windows are originally created with subrole == AXUnknown or isOnNormalLevel == false
        return app.bundleIdentifier == "com.apple.iBooksX"
    }

    private static func worldOfWarcraft(_ app: Application, _ role: String?) -> Bool {
        return app.bundleIdentifier == "com.blizzard.worldofwarcraft" && role == kAXWindowRole
    }

    private static func battleNetBootstrapper(_ app: Application, _ role: String?) -> Bool {
        // Battlenet bootstrapper windows have subrole == AXUnknown
        return app.bundleIdentifier == "net.battle.bootstrapper" && role == kAXWindowRole
    }

    private static func drBetotte(_ app: Application) -> Bool {
        return app.bundleIdentifier == "com.ssworks.drbetotte"
    }

    private static func dvdFab(_ app: Application) -> Bool {
        return app.bundleIdentifier == "com.goland.dvdfab.macos"
    }

    private static func sanGuoShaAirWD(_ app: Application) -> Bool {
        return app.bundleIdentifier == "SanGuoShaAirWD"
    }

    private static func steam(_ app: Application, _ title: String?, _ role: String?) -> Bool {
        // All Steam windows have subrole == AXUnknown
        // some dropdown menus are not desirable; they have title == "", or sometimes role == nil when switching between menus quickly
        return app.bundleIdentifier == "com.valvesoftware.steam" && (title != nil && title != "" && role != nil)
    }

    private static func mustHaveIfSteam(_ app: Application, _ title: String?, _ role: String?) -> Bool {
        // All Steam windows have subrole == AXUnknown
        // some dropdown menus are not desirable; they have title == "", or sometimes role == nil when switching between menus quickly
        return app.bundleIdentifier != "com.valvesoftware.steam" || (title != nil && title != "" && role != nil)
    }

    private static func firefox(_ app: Application, _ role: String?, _ size: CGSize?) -> Bool {
        // Firefox fullscreen video have subrole == AXUnknown if fullscreen'ed when the base window is not fullscreen
        // Firefox tooltips are implemented as windows with subrole == AXUnknown
        return (app.bundleIdentifier?.hasPrefix("org.mozilla.firefox") ?? false) && role == kAXWindowRole && size?.height != nil && size!.height > 400
    }

    private static func vlcFullscreenVideo(_ app: Application, _ role: String?) -> Bool {
        // VLC fullscreen video have subrole == AXUnknown if fullscreen'ed
        return (app.bundleIdentifier?.hasPrefix("org.videolan.vlc") ?? false) && role == kAXWindowRole
    }

    private static func androidEmulator(_ app: Application, _ title: String?) -> Bool {
        // rescue a titled emulator window that has a non-standard subrole (so isStandardSubrole missed it).
        // empty-title emulator windows are dropped elsewhere: the side menu by the size guard, the
        // transient overlay by mustHaveIfAndroidEmulator.
        return title != "" && ApplicationDiscriminator.isAndroidEmulator(app.bundleIdentifier, app.pid)
    }

    private static func mustHaveIfAndroidEmulator(_ app: Application, _ title: String?) -> Bool {
        // The emulator spawns a transient ~device-sized AXDialog with an empty title on every focus
        // change/summon; with a standard subrole it slips past the accept gate and flickers into the
        // switcher as "qemu-system-aarch64" (#5740). The real device window always has a title
        // ("Android Emulator - <avd>:<port>"), so require a non-empty title for emulator windows.
        return !ApplicationDiscriminator.isAndroidEmulator(app.bundleIdentifier, app.pid) || (title != nil && title != "")
    }

    private static func crossoverWindow(_ app: Application, _ role: String?, _ subrole: String?, _ level: CGWindowLevel) -> Bool {
        return app.bundleIdentifier == nil && role == kAXWindowRole && subrole == kAXUnknownSubrole && level == CGWindow.normalLevel
            && (app.localizedName == "wine64-preloader" || app.executableURL?.absoluteString.contains("/winetemp-") ?? false)
    }

    private static func isAlwaysOnTopScrcpy(_ app: Application, _ level: CGWindowLevel, _ role: String?, _ subrole: String?) -> Bool {
        // scrcpy presents as a floating window when "Always on top" is enabled, so it doesn't get picked up normally.
        // It also doesn't have a bundle ID, so we need to match using the localized name, which should always be the same.
        return app.localizedName == "scrcpy" && level == CGWindow.floatingWindow && role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    private static func autocad(_ app: Application, _ subrole: String?) -> Bool {
        // AutoCAD uses the undocumented "AXDocumentWindow" subrole
        return (app.bundleIdentifier?.hasPrefix("com.autodesk.AutoCAD") ?? false) && subrole == kAXDocumentWindowSubrole
    }
}
