# WindowEventReducer — the front of the MRU after a removal — Specs

## Summary

Covers `WindowEventReducer.refrontAfterRemovingTheFocusedWindow`: what happens to MRU slot 0 when the window
holding it is removed. Specs + Tests without a same-named kernel (like `WindowEventReducerPhantom`): the
subject is a reducer decision, not a pure function of its own.

The captured scenario is driven through `TestReducerRunner`, because the bug only appears as a SEQUENCE
(activation, two 808s, a removal); the rule-level scenarios drive `WindowEventReducer.reduce` directly.

## Why this exists (#5346)

The reporter's REAPER window stopped moving in the switcher: every alt-tab landed back on the window they
were already in, and the first tile was a Finder window they had left minutes ago. Their `--logs=debug`
capture (2026-07-27, v11.4.3) shows the exact instant it breaks:

    13:28:08.607 focusTarget (pid:681 finder) (wid:3449)      ← Finder takes MRU slot 0
    13:28:13.634 WS windowFocused wid=4557                     ← REAPER's "Insert Multiple Media Items",
    13:28:13.845 discovered a new window: (wid:4557)             opened by a drag while REAPER is BACKGROUND
    13:28:14.961 WS windowFocused wid=4557                     ← the click that dismisses it ACTIVATES REAPER
    13:28:14.962 WS windowFocused wid=4274                     ← the main window, 1 ms later
    13:28:16.960 deinit (wid:4557 title:Insert Multiple Media Items)

The dialog is discovered while its app is in the background, so the freshly-created promotion fronts it
(correctly — it IS the focused window). The click then activates REAPER, and of the two 808s that activation
emits, the first (the dialog) is the focus and the second (the main window) is the raise tail, which
`ActivationFocusResolver` swallows by design (#5596). Both decisions are right on their own. What was missing
is the third: when the dialog is removed, closing the MRU gap hands slot 0 to whoever held slot 1 — **Finder**,
an app that is not even frontmost.

Nothing corrected it afterwards, which is why the reporter saw it as permanent rather than as a glitch:
re-focusing the already-focused window of the already-frontmost app emits neither an activation nor an 808, so
each alt-tab (`13:28:42.720`, `43.671`, `44.680`, all `focusTarget (wid:4274)`) selected the window the user
was already in and left the order exactly as it was.

**The rule: macOS never moves focus to another app because a window closed.** So when the removed window held
slot 0, the front goes to the frontmost app's own next window, not to the global runner-up.

---

## Test scenarios

Mirrors `WindowEventReducerFocusTests.swift` 1:1.

### A. The captured #5346 sequence

- **testDialogClosingLeavesTheFrontmostAppInFront** — the transcribed REAPER capture: after the dialog is
  removed, the main window owns slot 0 and Finder is behind it. Without the re-front this ends `reaper=1
  finder=0`, which is the reported bug exactly (first tile Finder, alt-tab lands on the current window).
- **testTheSameSequenceWithoutTheActivationNeedsNoRepair** — the counterfactual that isolates the trigger:
  drop the activation and the main window's 808 is no longer a raise tail, so the ordinary focus path already
  puts it in front. The repair is what covers the activation timing, nothing else.

### B. The rule

- **testRemovingTheFocusedWindowPromotesTheFrontmostAppsNextWindow** — another app holds slot 1; the
  frontmost app's own next window is promoted over it, and `.applyFocus` names it.
- **testRemovingANonFrontWindowPromotesNothing** — a window at slot 2 closes: slot 0 is untouched, so nothing
  is re-fronted and no ordinary close churns the MRU.
- **testRemovingTheFrontmostAppsOnlyWindowPromotesNothing** — with no window left in the frontmost app there
  is nothing to promote, and the global shift stands (the app is about to go windowless).
- **testMinimizedWindowsAreNotPromoted** — a minimized window is not on screen and did not receive the focus
  the closing window gave up.
- **testInactiveTabsAreNotPromoted** — an inactive tab isn't on screen either; its group's representative is
  what the user sees.

### C. Restoring a minimized window (QA I-11, #5439's shape)

Restoring is the ONE AltTab focus that stirs the app's other windows: it deminiaturizes before focusing.
Every other AltTab focus raises exactly one window, which is why an AltTab-initiated activation normally
snapshots nothing (`ActivationFocusResolver.onActivation`) — and why that premise had to be narrowed here
rather than dropped. These two pin the reducer end: the kernel only learns the target was minimized because
`appActivated` reads it off our own model, and no kernel test can prove that call site passes it.

- **testRestoringAMinimizedWindowKeepsItInFrontOfItsSibling** — the transcribed capture: AltTab focuses the
  minimized window, macOS answers with a focus 808 for the SIBLING 38ms in, and the restored window must
  still own slot 0 with the sibling not moving at all. Without the fix the sibling takes slot 0 and the
  window the user picked is second — the reported bug exactly.
- **testFocusingANonMinimizedWindowStillLetsTheSiblingsFocusBump** — the counterfactual that keeps #5785
  safe: the same tail against a non-minimized target still bumps, because there no tail was caused. The two
  behaviours differ only by whether AltTab had to deminiaturize.

### D. The desktop being put back (#5936)

An order-in of the active app's window is read as a raise, because the native Cmd+` emits nothing else.
Three OS gestures break that reading, all with the same signature: every window of every app ordered in
inside one millisecond, and — unlike a Space re-show, an un-hide or a fullscreen exit — **no order-out
first**, so `offScreen` is empty and `cameBackOnScreen` cannot tell a re-show from a raise. Measured live
(macOS 26, 2026-08-12), each with the lag from its own signal to the burst:

| trigger | signal | lag | mute | notes |
|---|---|---|---|---|
| Mission Control / App Exposé | `AXExposeShowAllWindows` (Dock AX) | 12-106ms | 0.5s | the common one; caught doing the full damage |
| display wake / unlock | `screensDidWake` / `screenIsUnlocked` | 2.03s (×3) | 3s | only bites on a Mac that does not lock |
| display reconfiguration | `didChangeScreenParameters` | ~500ms | 1.5s | was surviving on luck inside `inSpaceTransition`, once by 28ms |

`WindowEventReducer.systemReshowMute(source)` sizes each mute for its own trigger, 3-5x that trigger's lag,
armed from `DockEvents`, `SleepWakeEvents` / `ScreenLockEvents` and `ScreensEvents`. One 3s window for all
three put the cost where users meet it: dismiss Mission Control, cycle windows a beat later, and the raise
lands inside a mute sized for a wake that never happened.

The wake case only bites where the screen does not lock: with loginwindow holding the front, the
app-is-active guard already swallows the burst. Mission Control has no such accidental cover, which is why
it is the trigger that reproduces on any Mac, at any time of day, with no idling involved.

- **testTheWakeBurstDoesNotReorderTheMru** — the measured burst against an interleaved MRU: no window is
  re-fronted and the order is untouched. Without the mute the active app's windows walk to the top in burst
  order, which is the report ("all my Chrome windows are at the front", after only stepping away).
- **testTheMissionControlBurstDoesNotReorderTheMru** — the capture that showed the damage in full: the
  frontmost app's three windows, at MRU 0, 2 and 3, all re-fronted 12ms after the Dock notification with
  nothing else in flight. Same rule, the trigger users actually hit.

Under the signals sits a BACKSTOP that needs none of them (`reshowBurstGap`, 5ms): a raise moves one window,
a re-show moves all of them at once, so an order-in landing within 5ms of an order-in for a DIFFERENT window
does not bump. It covers the race the signals cannot promise to win — both the Dock notification and the
burst reach the main queue by `async`, and three of ten measured rounds had them in the same millisecond —
and any re-show trigger nobody has wired a signal for. It cannot judge a burst's FIRST member, which is the
harmless one (the frontmost app's front window, at MRU 0 in both captures).

- **testABurstIsCaughtByItsShapeWithNoSignalArmed** — the same burst with nothing armed: the first member
  keeps the front it already had, the rest do not move.
- **testALoneOrderInStillBumps** — Cmd+` keeps working: an order-in arriving alone bumps, 200ms being under
  the fastest human action ever captured (219ms).
- **testTheSameWindowTwiceIsNotABurst** — one window reported twice in an instant is not two windows; that
  is the shape of every genuine focus, whose 808 and 815 land together.
- **testAnUntrackedWidCountsAsBurstEvidence** — the record covers the whole order-in stream, tracked or not,
  since a burst with holes in it stops looking like a burst.
- **testAnInAppRaiseStillBumpsOnceTheMuteExpired** — time-bounded, because the signal it stands in front of
  is real: past the window, an order-in is a Cmd+` raise again.
- **testAnInAppRaiseASecondAfterMissionControlStillBumps** / **testTheWakeMuteStillCoversItsOwnLateBurst** —
  the pair that pins the per-source sizing from both ends: a raise 1s after Mission Control bumps, while a
  burst 2.03s after a wake does not. A single 3s mute fails the first; a single 0.5s mute fails the second.
- **testAFocusEventDuringTheMuteStillBumps** — only the order-in path is muted. An 808 is the OS stating a
  focus rather than us inferring one, and the burst contains none.
- **testRestoringAMinimizedWindowDuringTheMuteStillBumps** — an un-minimize is spared, as it is spared the
  `cameBackOnScreen` exclusion: a wake leaves minimized windows minimized, and a Dock restore inside the
  frontmost app emits ONLY that order-in, so a swallowed bump would never be corrected (#5439).

### E. An app raising ALL its windows while already frontmost (#5974)

The report: a notification banner arrives, the app brings its whole window set to the front, and every other
app is pushed under it — "Alt-Tab's Z-order is broken". Measured on macOS 26.6 (2026-08-21), the app emits
one 808 plus one 815 per window, 29ms apart, and **no `didActivateApplication` at all**. With no activation
entry to consult, each 808 falls through to "bump iff the app is active" and walks its window to the top:

```
BEFORE  C1(0)  SystemSettings(1)  C2(2)  Claude(3)  C3(4)
18:26:01.417 windowFocused   #51249 | mru bump #51249 from=4
18:26:01.417 windowOrderedIn #51249 | mru bump #51249 from=0
18:26:01.446 windowFocused   #51241 | mru bump #51241 from=3
18:26:01.446 windowFocused   #51228 | mru bump #51228 from=2
18:26:01.446 windowOrderedIn #51228 | mru bump #51228 from=0
AFTER   C1(0)  C2(1)  C3(2)  SystemSettings(3)  Claude(4)
```

**The bit that separates a focus from a raise is not in the event stream and not in the WindowServer.** The
808 payload is 4 bytes (the wid) and is byte-identical for both; probing ids 800-830 found no sibling that
fires only on a real focus. The WindowServer models no "key window": `SLSWindowIteratorGetTags` and
`GetAttributes` read byte-identical across key vs non-key, across a raise that changed z-order, and across
the app being active vs inactive, and every focus getter SkyLight exports is process-scoped. z-order cannot
stand in for it either — a raise-all leaves the LAST window raised on top, not the one holding keys.

So this is deliberately **not** another timing guard. `focusBurstGap` (100ms) only says "judgement is
suspended for this app"; the verdict comes from the one oracle that knows, the app's own `kAXFocusedWindow`,
read once the run goes quiet (`.resolveFocusAfterBurst` → `.focusBurstResolved`). The timer chooses WHEN to
read, never WHAT the answer is — which is what separates this from the two burst-SHAPE attempts that were
reverted (`9f60c241`), where a threshold had to tell a raise tail's 118-334ms lag from a 219ms human action.

100ms sits between the two measured populations: an app raising its own windows one at a time is 29ms apart,
and the fastest human action in any capture is 219ms (#5785). It is far wider than the 815 path's
`reshowBurstGap` (5ms), which measures a WindowServer re-show at ~0.12ms between members.

Three properties make the answer expressible where a bump-based rule could not reach it. The read may say
**nobody moved**, which is the correct answer here and is why the run's first member carries a rollback: that
first 808 is bumped before anything could reveal a run, and in the capture it was the window at MRU 4. The
rollback restores the RANK as well as the timestamp — ranks are re-derived from `focusedAt`, and windows
nothing was ever seen focused on are all ties that would otherwise keep the scrambled order. And the run
holds back the app's ORDER-INS too, since each raise carries an 815 in the same millisecond that would
otherwise re-front exactly what the 808 was held for.

- **testAnAppRaisingAllItsWindowsLeavesTheMruAlone** — the capture, replayed: the app still says C1 has keys,
  so the whole run resolves to zero net bumps and the interleaved order is exactly as the user left it.
- **testTheBurstResolvedToAMemberFrontsThatOneAlone** — the same run resolved to a different member: that one
  window fronts, nothing else of the app's moves, and it is stamped at the run's FIRST 808 so anything the OS
  focused while the read was in flight still outranks it.
- **testATwoWindowBurstResolvedToTheFrontRollsTheSpeculativeBumpBack** /
  **testATwoWindowBurstResolvedToTheFirstMemberKeepsItsBump** — both verdicts on the smallest run there is.
  Both have to be reachable, or the read is decoration.
- **testALoneFocusEventBumpsWithoutAskingTheApp** — the fast path is untouched: a lone 808 bumps on the spot
  and spends no AX read. That is the overwhelming majority of this stream.
- **testTwoFocusesABeatApartAreNotABurst** — 300ms apart is two focuses, past the gap and past the fastest
  human action ever captured.
- **testTheSameWindowFocusedTwiceIsNotABurst** — one window reported twice is not a run of different windows;
  `Window.focus()` fires several calls for one wid. Mirrors the 815 path's own rule.
- **testAltTabsOwnFocusInsideABurstStillBumps** — the objection that makes this safe to ship. Focusing a
  window of the already-frontmost app raises no app, so `altTabIntentToRecord` deliberately keeps nothing
  (#5596) and the switch rides on one 808; held back with the run it would be lost for good, since
  re-focusing an already-focused window emits nothing at all. Hence a separate same-app record, read ONLY
  here. Resolved with a FAILED read on purpose: the bump must not depend on the oracle answering.
- **testOrderInsAreHeldWhileAFocusBurstIsInFlight** — the 815 half, and it is load-bearing: without it the
  suppressed 808s are simply re-fronted by their own order-ins 29ms later, which `reshowBurstGap` cannot see.
- **testAnUntrackedFocusInsideABurstIsNotPromoted** / **testAnUntrackedFocusOutsideABurstIsStillPromoted** —
  an untracked member is the window we know least about, so it does not front itself on arrival while the
  run's tracked windows are held; if the app names it, the promotion is armed then. Outside a run the
  promotion stays exactly as it was (#5785).
- **testAStaleReadNamingAnOutsiderChangesNothing** — `kAXFocusedWindow` is answered at all times, whether or
  not anything just happened, so an answer naming a window the run never touched decides nothing.
- **testAnUnresolvedBurstLeavesTheSpeculativeBumpStanding** — a read that failed outright leaves today's
  behaviour in place rather than guessing in the oracle's place.
- **testALateAnswerDoesNotCloseTheNextRun** — the read is asynchronous and `AXCallScheduler` holds a second
  call for the same key until the first returns, so run N's answer can arrive after run N+1 opened. It must
  not close it: the held focus events would be dropped with nothing behind them to correct the order. Hence
  `runStartedAt`, carried out on the effect and back on the input, naming the run being answered.
- **testAnOrderInOnlyRaiseInsideABurstIsStillResolvable** — a window can join a run through the order-in path
  alone, since the native Cmd+` raise emits an 815 and no 808. Holding its bump and then rejecting the
  verdict that names it as "no member of the run" would swallow that raise twice over (#5875, #5439), so a
  held order-in is recorded as a MEMBER and not merely as a heartbeat.
- **testAnUntrackedOrderInInsideABurstIsNotPromoted** / **testAnUntrackedMoveIsNotMistakenForABurstMember** —
  the hold covers the untracked order-in too, or an undiscovered window of the bursting app fronts itself on
  arrival and keeps the scramble alive on its own. Gated on the event really being an order-in: a move/resize
  reaches the same code carrying no `now`, and a zero timestamp reads as "inside every run that ever started".
- **testTheRollbackSurvivesAGenuineFocusLandingMidRun** — the undo re-seeds the whole pre-run tiebreak rather
  than restoring the window's own position. An index puts it back a slot too far forward once a genuine focus
  mid-run has shifted everything behind it, and an anchor row drags it along when the anchor is what the user
  focused. `recomputeFocusRanks` still sorts by `focusedAt` first, so the window the user really clicked keeps
  the front it earned.
- **testAnActivationStormIsStillTheActivationResolversAlone** — inside a live activation none of this
  applies: that storm is the OS's own and `ActivationFocusResolver` rules it alone (first 808 = the focus,
  raise tail swallowed). Double-judging it is how #5596 was reopened twice.
