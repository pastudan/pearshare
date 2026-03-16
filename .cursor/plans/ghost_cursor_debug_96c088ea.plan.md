---
name: Ghost cursor debug
overview: Systematically debug why the red ghost cursor on LAPTOP keeps snapping to the system cursor position when MACMINI has control, despite multiple attempted fixes.
todos:
  - id: log-tap-deltas
    content: Add os_log inside tap .mouseMoved branch — confirm tap is firing and check if deltas match physical movement or system cursor jumps
    status: completed
  - id: log-tap-all
    content: Add log at top of tapCallback — confirm injected events (tagged) are not reaching the tap despite kCGSessionEventTap injection
    status: completed
  - id: absolute-position
    content: Replace delta accumulation in tap with absolute event.location read — eliminate drift from delta math entirely
    status: pending
  - id: flip-tap-levels
    content: Move tap to cgannotatedSessionEventTap, inject at cghidEventTap — flip levels so injection and suppression don't interfere
    status: pending
  - id: hide-cursor-approach
    content: "Drop tap entirely: CGDisplayHideCursor when viewer has control, CGWarpMouseCursorPosition for viewer moves, SwiftUI overlay for host ghost"
    status: pending
isProject: false
---

# Ghost Cursor Debug Plan

## What we've tried (all in [ControlChannel.swift](clients/macos/PearShare/Media/Control/ControlChannel.swift))

- `CGAssociateMouseAndMouseCursorPosition(false)` — only works when app is foreground, silently did nothing
- `CGEventTap` at `cghidEventTap` to suppress physical mouse — worked, but injected events re-entered the tap and corrupted delta math
- Tag injected events via `event.setIntegerValueField(.eventSourceUserData, ...)` — unreliable because the field doesn't survive the HID pipeline round-trip
- `guard currentController == .host` in `hostMouseMonitor` — necessary but not sufficient
- Tag filter in `hostMouseDownMonitor` to stop injected clicks from bouncing control — correct, but didn't fix ghost position
- Proper `CGEventSource` with `userData` — better tagging, but...
- Inject at `kCGSessionEventTap` (rawValue 1) instead of `cghidEventTap` — bypasses HID tap so injected events don't re-enter... but bug persists

## The exact bug (clarified)

Trigger: MACMINI has control and **simply moves the mouse** (no click, no control transfer).
Result: The next time LAPTOP tries to move the red ghost cursor, it starts from a position near where the system cursor currently is — not from where the red cursor was last drawn.

This means something is overwriting `hostPosition` or `suppressionTap.ghostPosition` on a plain mouse move by MACMINI. The move path on the host is:

1. MACMINI sends `mouseMoved(nx, ny)` over the network
2. Host `handleViewerEvent` → `moveCGCursor(to: cgPt)` → posted at `kCGSessionEventTap`
3. Suppression tap is at `cghidEventTap` — should NOT see session-level injected events
4. `hostMouseMonitor` has `guard currentController == .host` — should NOT update `hostPosition`

If none of those fire, `hostPosition` should be unchanged. The logs (todos 1 & 2) will tell us which assumption is wrong.

## Ideas to try (in order)

**1. Add os_log to prove what's firing** — Add a single log line inside the tap's `.mouseMoved` branch before delta accumulation: `logger.debug("tap delta dx:\(dx) dy:\(dy) ghost:\(s.ghostPosition)")`. Run a session, move LAPTOP trackpad while MACMINI has control, then check Console.app. This will confirm whether the tap is firing at all, and whether the deltas match physical movement or system cursor jumps.

**2. Check if `kCGSessionEventTap` injection actually bypasses our tap** — Add a log line at the very top of `tapCallback` (before the tag check): `logger.debug("tap saw event type:\(type.rawValue) tag:\(event.getIntegerValueField(.eventSourceUserData))")`. If we see events with our tag arriving despite injecting at rawValue 1, the tap location assumption is wrong.

**3. Drop the delta approach entirely — use absolute position from `CGEventGetLocation`** — Instead of accumulating deltas in the tap, read the raw hardware cursor position from the event itself. At `cghidEventTap`, before the window server processes position, `event.location` contains the hardware absolute position. If we replace `ghostPosition += deltas` with `ghostPosition = NSPoint(x: event.location.x, y: ...)` for untagged events, we skip delta math entirely. This is cleaner if deltas are the source of drift.

**4. Move the suppression tap to `cgannotatedSessionEventTap` and inject at `cghidEventTap`** — Flip the levels: inject at HID (so cursor moves reliably), suppress at session level. Physical events go HID → session, injected events enter at HID but are filtered at session by source tag.

**5. Skip the tap entirely — use `CGWarpMouseCursorPosition` + `CGDisplayHideCursor`** — Simpler model: when viewer has control, hide the system cursor on LAPTOP entirely (`CGDisplayHideCursor`), and use `CGWarpMouseCursorPosition` directly for the viewer's movements. LAPTOP's red ghost is just a SwiftUI overlay we position manually from `hostPosition`. No tap needed at all.

## Recommended order

Start with 1 and 2 (pure logging, no code risk) — the logs will tell us which of 3/4/5 is the right fix.