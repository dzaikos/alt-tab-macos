# What may move the window order — Specs

One engine decides which window the user is looking at: `AttentionModel`, fed by `AttentionDriver`, driven by
`AttentionEngine`. There is no second engine, no mode, and no runtime switch. To compare against the old
behaviour, check out the last commit before the rework and run the same QA suite against that build.

## The whole system, in one place

    NSWorkspace activation ─┐
    AltTab's own switch ────┼─→ TrackedWindowStateBridge.dispatch ─→ AttentionEngine.dispatched ─┐
    kAXFocusedWindow read ──┘                                                                    │
                                                                                                 │
    the app's AXObserver ─→ AxObserverRegistry ─→ AttentionEngine.axSemanticFocus (60ms settle) ─┤
                                                                                                 │
    the click (type 13) ──→ WindowAttentionEvents ─→ AttentionEngine.directedAttention ──────────┤
                                                                                                 ▼
                                             AttentionDriver.translate ─→ AttentionModel.reduce
                                                                                                 │
                                          .front(target) ─→ ReducerInput.attentionCommitted ──────┘
                                                                     │
                                            WindowEventReducer.applyFocusAndBump ─→ the order

- **`AttentionModel`** is the pure kernel and holds the two levels (`AttentionModelSpecs.md`).
- **`AttentionDriver`** translates the reducer's vocabulary into the model's, and allocates arrival
  sequences (`AttentionDriverSpecs.md`).
- **`AttentionEngine`** is the impure shell: process generations, the per-process settle, the commit.
- **`TrackingTelemetryRecorder`** only observes. Switching it off cannot change what AltTab does.

## Who may write the order

- **an attention decision** — a click or Cmd+` naming its target, AltTab's own switch, or an app answering
  which of its windows it considers focused. The only source that may claim the user moved.
- **a structural repair** — the front window closed and something has to take its place, or a tab group
  changed which member it draws. Not a claim about the user at all.

Nothing else. `WindowEventReducer.applyFocusAndBump` is the only function that writes `focusedAt`, and it
takes an `AttentionWriteSource` naming which of the two entitled it. In particular the WindowServer's order
and focus family (808/815/816) cannot move the order: measured across twelve scenarios, it never names a
window accessibility had not already named, it always names it later, and on an activation it fires once per
on-Space window, which is a set rather than an answer.

## What physical events keep

Everything except the order. Visibility, geometry, Space membership, tab membership, phantom verdicts,
discovery and invalidation are all still driven by the WindowServer, and none of them changed.

## Where the decision lands

Inside the same dispatch that produced it (`TrackedWindowStateBridge.dispatch`). A decision deferred to the
next runloop turn would let the switcher draw one frame with the old order first, which the QA matrix scores
as "right, but late" rather than right.

A decision naming a window nobody tracks is ignored, never fabricated.

## What is deliberately not covered

The engine cannot invent an attention edge it never observed. When an app activation names no window and
accessibility never answers, the order does not move: the last confirmed window keeps the front. That is a
worse-looking but safer answer than guessing from z-order, and it is the central discipline of the design.

The price is known and was accepted: a window that never took keys has no attention record at all, so it
sorts behind every window the user has ever focused rather than near the front as it used to.

## The one timing constant

`AttentionEngine.semanticSettle` (60ms) collapses an app's burst of answers to its last one — an app raising
all its windows answers once per window, each answer true, and the run ends where it started (#5974). It is
the only wall-clock number left in the attention path. Widening it is not free: it delays every genuine
switch by the same amount, against a measured floor of 219ms for the fastest human action ever captured.
Raises spaced wider than the settle commit separately and #5974's shape returns; QA A-11 watches that limit
in amber rather than asserting it away.
