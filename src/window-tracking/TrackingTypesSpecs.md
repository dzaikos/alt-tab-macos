# Tracking identities — Specs

The identity types every rule in the attention pipeline keys on. There is no behaviour here; the point is
that a pid and a wid are both reusable, so neither is an identity on its own.

- **`ProcessGeneration`** — a pid plus the generation AltTab assigned it. macOS reuses pids, so a callback
  from a process that has already died would otherwise read as current. Every per-app fact, every AX observer
  entry and every attention record is keyed on this.
- **`WindowIdentity`** — a wid qualified by its owning process generation, for the same reason: the
  WindowServer reuses wids too.
- **`IngressSequence`** — arrival order, allocated when evidence reaches the model. Compared per process and
  nowhere else (`AttentionModelSpecs`, R1).
- **`MonotonicTimestamp`** — the clock the AX observer health budgets and cooldowns run on. Monotonic so a
  wall-clock jump cannot make a retry look overdue.
- **`TrackingProvider`** — who told us. Telemetry only, so a disagreement is attributable to a channel.
- **`AttentionWriteSource`** — what entitles a call to move the window order. See `AttentionOrderSpecs.md`.

## Test scenarios

- **testProcessGenerationSeparatesPidReuse** — a reused pid is a different process.
- **testWindowIdentityOrdersByProcessThenWid** — the same wid under two generations is two windows.
- **testIngressSequenceOrders** — arrival order is a total order.
