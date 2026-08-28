# AxObserverHealth — Specs

## Ownership

`AxObserverHealth` is a pure registry and reducer. It models one observer entry for each live PID generation,
classifies subscription outcomes, and emits lifecycle decisions. It neither imports Accessibility APIs nor
infers window focus. The impure registry is responsible for creating one observer/runloop source, applying
decisions, and cancelling the generation synchronously on teardown.

## Capabilities and lifecycle

- The initial capability set is exactly focused-window changed, main-window changed, window-created, and
  title-changed. Focused-UI-element changed is deliberately not representable.
- Title-changed is the only capability ever added to that set. It replaces AX reads the app was already
  making against every app on every order event, it is a window-level notification rather than an
  element-level stream, and it registered on every app owning user-facing windows in the 52-app probe.
- Each notification moves independently through unattempted, subscribing, subscribed, unsupported, or a
  timestamped cooldown. An unsupported or not-implemented notification never removes another capability or
  makes a responsive provider unresponsive.
- Provider lifecycle is distinct from notification capability: unregistered, registering, healthy, degraded,
  unresponsive, recovering, or global permission failure.
- Diagnostics retain the total and per-capability attempt counts, independent per-capability cannot-complete
  tiers, observer generation, last error, last success/callback, and next retry. A process-wide refusal count is
  the maximum outstanding capability tier. The capability set is derived only from subscribed notifications.

## Error and retry policy

- Success and already-registered subscribe only the attempted notification. Unsupported and not-implemented
  mark only that notification unsupported.
- Cannot-complete marks the PID unresponsive. Each notification has its own bounded exponential short budget;
  subsequent failures enter the sparse tier, which itself doubles from the initial sparse delay up to the
  cooldown and stays there — an app that starts answering again is asked within seconds rather than waiting
  out a flat cooldown. Success or callback for one notification cannot reset another's tier. Expiry makes
  recovery eligible but never declares the provider healthy.
- Invalid UI element and invalid observer invalidate outstanding completion tokens, advance the observer
  generation, preserve known unsupported capabilities, and require a rebuild.
- Invalid argument and generic failure degrade the PID and enter sparse cooldown.
- API-disabled is global. Every existing, newly started, or replacement PID immediately reflects the global
  failure and stops attempting independently until one global permission-restored input starts recovery and
  advances existing observer generations.
- Frontmost, new-window, dirty-semantics, wake, unlock, successful AX call, and low-frequency tick are bounded
  recovery triggers. They respect the next retry time except that a real successful AX call proves liveness and
  may recover immediately.

## Generation and teardown

- The registry is keyed by PID and therefore cannot hold two observer states for the same process. Starting a
  replacement `ProcessGeneration` synchronously replaces the old entry and reports its cancelled observer
  generation.
- Subscription results and callbacks carry both process and observer generations. Late work from a replaced,
  rebuilt, or torn-down observer is ignored.
- Teardown removes the entry and reports the observer generation to cancel. Reusing the PID begins with fresh
  notification, attempt, retry, and observer-generation state.

## Tests

Tests pin every result classification, independent capability refusal budgets, exponential and sparse retry
boundaries, cooldown/recovery triggers, callback diagnostics, global permission gating including processes
started or replaced during failure, rebuild generation rejection, teardown/PID reuse, and the one-entry-per-PID
invariant.
