# WindowAdmissionResolver — Specs

## Product object

AltTab offers switch destinations, not every rectangle WindowServer paints. `PhysicalSurface` owns existence,
geometry, level and parentage. `SemanticSurface` owns AX meaning. `SwitchDestinationDecision` joins them without
giving either source universal authority.

## Rules

1. WID zero is invalid.
2. A WindowServer parent is an exact relationship: represent the parent, regardless of level, size or attention.
3. Exact attention makes a parentless surface a destination even when AX is absent or unconventional.
4. An AXWindow marked `kAXMain` is a destination.
5. `AXStandardWindow` is a destination. A titled `AXDialog` is a destination; an untitled one remains latent.
6. Floating/system-dialog surfaces are auxiliary unless parentage, mainness or attention already established a
   stronger result.
7. A substantial, titled AXWindow root is a custom-toolkit destination. This generic rule replaces app-name
   exceptions for Steam, Wine, presentation windows and similar unconventional apps.
8. Size and level are acquisition priors, not absolute rejection gates. Level-zero surfaces are inspected even
   when small; substantial surfaces are inspected at every level; exact attention bypasses the optimization.
9. A result is recomputed whenever semantic evidence is refreshed. No acceptance or rejection is permanent.

## Boundaries

`100×50` is substantial. Native AppKit tabs are logical destinations handled by `TabGroupResolver`; WindowServer
parentage intentionally says nothing about them because both active and background native tabs report parent zero.

## Application boundary

Window admission and application admission use the same evidence without conflating their permissions. Ordinary
discovery still excludes XPC processes unless they are an established user-facing exception. Exact attention may
admit the process which owns that destination; zombie status always rejects it. Owning an exact destination does not
grant speculative placeholders: only regular apps get one. An accessory or prohibited process that briefly took
focus (Raycast's palette, CoreServicesUIAgent's Gatekeeper alert) is not an app the user can switch back to.
