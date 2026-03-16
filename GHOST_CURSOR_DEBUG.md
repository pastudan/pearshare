# Ghost Cursor Debug Log

## The Bug

When MACMINI (viewer) has control, LAPTOP's red ghost cursor visually tracks the
real system cursor instead of moving independently with LAPTOP's trackpad.

**Root cause (diagnosed):** `CGWarpMouseCursorPosition` is called at 60fps to follow
MACMINI's cursor on LAPTOP's screen. Each warp — even a 2px one — generates a HID
"correction event" with a matching small delta. Our magnitude filter (>30) only
catches large warp corrections; small ones pass through and get accumulated into the
ghost position. Both the ghost and the system cursor end up tracking MACMINI.

---

## What We've Tried

| Attempt | Result |
|---|---|
| Magnitude filter (>30px) in tap | Catches large warp corrections but not small incremental ones |
| `CGAssociateMouseAndMouseCursorPosition(false)` in tap `enable()` | No effect — PearShare host runs as `.accessory` and is never frontmost, so the call silently does nothing |
| `NSApp.activate(ignoringOtherApps: true)` before `CGAssociate(false)` | **Most recent attempt** — should make the process active so `CGAssociate` takes effect; untested as of this commit |

**Key fact:** `CGAssociateMouseAndMouseCursorPosition(false)` is the *correct* API.
With association disabled the system has no cursor/mouse reconciliation to do, so
`CGWarpMouseCursorPosition` generates **no correction events at all**. The problem
is just making the call take effect when PearShare isn't frontmost.

---

## Things to Try Next

1. **Verify `NSApp.activate` worked** — log `NSApp.isActive` right before `CGAssociate`
   to confirm we're actually active when the call is made. If false, the frontmost
   restriction is the blocker.

2. **Inject mouse moves instead of warping** — replace `CGWarpMouseCursorPosition` in
   `moveCGCursor` with a proper injected `mouseMoved` CGEvent (tagged with our
   `eventTag` so the tap ignores it). Injected events at `kCGSessionEventTap` don't
   generate HID correction events because they're not raw hardware input.

3. **Stop warping for `mouseMoved` entirely** — remove `moveCGCursor` from the
   `mouseMoved` handler so no corrections are ever generated. Tradeoff: MACMINI's
   pointer won't give LAPTOP hover effects between clicks. Hover only updates on click.
   Cleanest fix if the CGAssociate approach keeps failing.

4. **Read absolute `event.location` instead of delta accumulation** — at the HID tap
   level, `event.location` on a physical trackpad event reflects the hardware pointer
   position *before* any cursor association logic. Use that as the ghost position
   directly instead of accumulating dx/dy. Eliminates all drift from delta math.

5. **Separate process / launchd helper** — run the `CGAssociate` call from a small
   privileged helper that can always claim to be foreground. Nuclear option, probably
   overkill, but would definitively solve the frontmost restriction.

---

## Architecture Reminder

```
LAPTOP (host)                          MACMINI (viewer)
─────────────────────────────────      ─────────────────────────────────
MouseSuppressionTap (cghidEventTap)    Blue overlay C  ← ctrl.onLocalCursorMoved
  • swallows LAPTOP physical events    Red overlay D   ← ctrl.onRemoteHostCursorMoved
  • accumulates ghost via dx/dy        System cursor A (hidden when host has control)
  • onReclaim → host reclaims control

Red ghost overlay D (hostGhostOverlay)
System cursor driven by CGWarpMouseCursorPosition
  ← called for every MACMINI mouseMoved at ≤60fps  ← THIS IS THE CORRUPTION SOURCE
```
