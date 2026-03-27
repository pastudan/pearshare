# PearShare — Input Control Model Spec

## Glossary

| Symbol | What it is |
|--------|-----------|
| **Host cursor** | The real system cursor on the host's machine |
| **Ghost (host)** | Red overlay on BOTH screens showing where the host's cursor is when they don't have control |
| **Pointer (viewer)** | Blue overlay on BOTH screens showing where the viewer's cursor is |
| **System cursor (viewer)** | The viewer's own local cursor — hidden inside the session window when host has control |
| **K&M toggle** | The keyboard icon on the host banner — opt-in, defaults off |

## Current State Machine

There are effectively two axes:

```
currentController = .host | .viewer       (who drives the real host cursor)
inputEnabled      = true  | false         (host has opted-in to K&M sharing)
```

`inputEnabled=false` is the *watch-only* mode. `inputEnabled=true` is *interactive* mode.
The five scenarios below all assume `inputEnabled=true` unless noted.

---

## What each overlay is, and when it should be visible

### On the HOST screen

| Overlay | Color | Label | Visible when |
|---------|-------|-------|--------------|
| Viewer pointer | Blue | peer's name | Host has control (viewer is pointing) |
| Host ghost | Red | "Me" | Viewer has control (host cursor is suppressed, ghost tracks deltas) |

### On the VIEWER screen

| Overlay | Color | Label | Visible when |
|---------|-------|-------|--------------|
| Viewer pointer ("Me") | Blue | "Me" | Host has control AND viewer's mouse is inside the session window |
| Host ghost | Red | peer's name | Viewer has control (shows where host's cursor is) |
| System cursor | n/a | n/a | Viewer has control OR mouse is outside session window |

---

## Scenario A — HOST has control, VIEWER is watching and pointing

*The most common state at session start.*

### What should happen

**Host machine:**
- Host cursor moves and clicks normally; cursor visible in the video stream
- Blue "viewer pointer" overlay follows viewer's mouse in real-time
- Host keyboard works normally
- Host sees: their own real cursor + blue overlay showing where viewer is pointing

**Viewer machine:**
- System cursor is **hidden** inside the session window
- Blue "Me" overlay replaces the cursor, following mouse movement
- Mouse moves are sent to host as `mouseMoved` events → drives the viewer pointer overlay on both sides
- Mouse clicks are sent to host as `mouseButton` events → **held pending control transfer check**
  - Because `inputEnabled=true` and `currentController=.host`, the first `mouseDown` **transfers control to viewer** (see Scenario D)
- Keyboard events are **not** sent (or if sent, dropped on host side)
- Viewer sees: blue "Me" overlay tracking their mouse, host's cursor visible in the stream

### Current bugs
- Viewer keyboard events are monitored and transmitted even when host has control; they're dropped host-side but the send is wasteful
- When `inputEnabled=false`, viewer's cursor is still hidden and the blue overlay is still shown — but the viewer can never take control, making the overlay misleading. In watch-only mode the viewer should have their real cursor.

---

## Scenario B — HOST is pointing/watching, VIEWER has control

### What should happen

**Host machine:**
- Physical mouse input is **suppressed** at the HID level (suppression tap active)
- Host's cursor does not move; system cursor hidden from the video stream
- Red "Me" (host ghost) overlay tracks host's physical mouse via raw delta accumulation
- Ghost position is streamed to viewer at ≤60 fps as `hostCursorMoved` events
- Host keyboard: **not suppressed** — host can still type on their own machine (this is intentional; host always retains keyboard)
- Host sees: red ghost showing their own cursor position; viewer's real cursor moves the actual cursor in the stream

**Viewer machine:**
- System cursor is **visible** (viewer drives the real host cursor)
- Red "host ghost" overlay follows the host's ghost position (driven by `hostCursorMoved` events)
- Mouse moves → `moveCGCursor` on host → moves the real cursor on host screen
- Mouse clicks → injected on host via CGEvent
- Keyboard events → injected on host via CGEvent
- Scroll events → injected on host via CGEvent
- Viewer sees: their own real cursor + red ghost showing where host's cursor "is"

### Current bugs
- The host's physical click is swallowed by the suppression tap when reclaiming (Scenario E). Intentional, but jarring — host must mentally commit a "reclaim" click that does nothing on their own machine.
- No visual indication on host that their keyboard is still active (they could accidentally type while the viewer is working, interleaving input)
- The viewer's cursor warps to host display coordinates, but the coordinate mapping may have issues on multi-monitor setups (only maps to `CGMainDisplayID()`)

---

## Scenario C — HOST has control and is actively using their machine, VIEWER is also moving mouse

*Same state as A but both parties are actively moving.*

### What should happen

This is just A in motion. Both parties should see smooth updates:

**Host sees:**
- Their own real cursor moving (normal)
- Blue viewer pointer overlay moving independently, tracking the viewer's mouse
- These are two fully independent things — they don't interfere with each other

**Viewer sees:**
- Blue "Me" overlay tracking their own mouse (system cursor hidden inside window)
- Host cursor visible in the stream, moving normally

### What should NOT happen
- Viewer's mouse moves should not affect where the host's cursor goes while host has control (the `moveCGCursor` call is guarded by `currentController == .viewer` — this is correct)
- The two overlays should not "fight" each other

### Current bugs
- In practice the overlays can flicker or jump if the UDP packets arrive slightly out of order or with bursts. There is no sequence numbering or smoothing on overlay position updates.

---

## Scenario D — VIEWER clicks to take control, then both parties move mouse

*Control transfer from host → viewer.*

### What should happen — the transfer moment

1. Viewer's `mouseDown` (left) is sent to host as `mouseButton(left, down=true)`
2. Host sees: `inputEnabled=true`, `currentController=.host`, `down=true` → initiates transfer
3. Host:
   - Records current `hostPosition` as ghost anchor
   - Enables suppression tap with `initialPosition = hostPosition`
   - Sets `currentController = .viewer`
   - Sends `controlTransfer(.viewer)` to viewer
   - Fires `onControlTransfer(.viewer)`:
     - Hides viewer pointer overlay (vco)
     - Shows host ghost overlay (hgo) at current hostPosition
     - Calls `setShowsCursor(false)` (removes cursor from stream)
4. Viewer receives `controlTransfer(.viewer)`:
   - `viewerIsInControl = true`
   - Hides "Me" blue overlay (vlo)
   - Shows system cursor
   - Shows red host ghost (vho)

**Critical question: does the click that triggered the transfer also perform a click on the host?**

In the current code: **yes** — after `transferControl(to: .viewer)` sets `currentController = .viewer`, the code falls through to `injectMouseButton(...)`. The click both transfers control AND fires on the host machine. This is usually wrong — the viewer intended the click to take control, not to click something on the host's screen.

**What should happen instead:** The control-transfer click should be **consumed** — it takes control, does not fire on the host. Only subsequent clicks (after the `controlTransfer` round-trip completes) should be injected.

### What should happen — after transfer, both moving

**Host:** suppression tap active, physical mouse suppressed. Ghost moves. Red ghost overlay on host screen tracks host's physical movement. Viewer's cursor moves the real host cursor.

**Viewer:** real cursor visible. Red ghost shows host's passive position. Viewer's moves are injected on host. Both cursors visible simultaneously on viewer screen.

### Current bugs
- The triggering `mouseDown` is injected on the host (see above) — often causes unintended clicks
- The corresponding `mouseUp` for the same click is also injected, potentially completing a click on whatever the host cursor was over
- No visual "handshake" feedback — the viewer doesn't know the transfer succeeded until the `controlTransfer` UDP packet arrives back, which could be 5–50 ms later, during which the viewer's clicks could cause undefined behavior

---

## Scenario E — HOST clicks to take back control, then both parties move mouse

*Control transfer from viewer → host.*

### What should happen — the reclaim moment

1. Host clicks physically (while suppression tap is active)
2. Suppression tap intercepts the `mouseDown` → calls `onReclaim` → `hostDidClick()` → `transferControl(to: .host)`
3. Host:
   - Warps system cursor to `hostPosition` (so cursor snaps to ghost's last position)
   - Disables suppression tap → physical mouse re-enabled
   - Sets `currentController = .host`
   - Sends `controlTransfer(.host)` to viewer
   - Fires `onControlTransfer(.host)`:
     - Shows viewer pointer overlay (vco)
     - Hides host ghost overlay (hgo)
     - Calls `setShowsCursor(true)` (cursor back in stream)
4. Viewer receives `controlTransfer(.host)`:
   - `viewerIsInControl = false`
   - Hides red host ghost (vho)
   - Hides system cursor
   - Positions and shows blue "Me" overlay at current mouse location (vlo)

**The reclaim click is consumed by the tap** (returns `nil`) — it does NOT fire on the host machine. The host must make a dedicated "reclaim" click that does nothing else. This is a design tradeoff: prevents accidentally clicking something on their own machine at the moment of reclaim, but requires a "wasted" click gesture.

### What should happen — after reclaim, both moving

Back to Scenario A/C. Host has their cursor at `hostPosition` (wherever ghost was). Viewer's blue overlay resumes.

### Current bugs
- Cursor snap to `hostPosition` can be jarring if the host's ghost drifted far from where the viewer was working
- The `hostMouseDownMonitor` (global NSEvent monitor fallback for reclaim) can sometimes fire on **injected** viewer clicks that pass through to the session-level event tap — this is defended against with the `eventTag` check, but the defense may not be 100% reliable
- After reclaim, the viewer's system cursor is immediately hidden inside the session window. If the viewer was mid-interaction (e.g., holding a drag), the transition may leave dangling held-button state

---

## Summary table

| Scenario | currentController | Host cursor | Host sees | Viewer cursor | Viewer sees |
|----------|-------------------|-------------|-----------|---------------|-------------|
| A — host in control | `.host` | Real, visible in stream | Their cursor + blue viewer pointer | Hidden (inside window) | Blue "Me" overlay |
| B — viewer in control | `.viewer` | Suppressed (ghost active) | Red "Me" ghost | Real system cursor | Their cursor + red host ghost |
| C — A but both moving | `.host` | Real | Their cursor + moving blue overlay | Hidden | Moving blue "Me" overlay |
| D — viewer just took control | `.viewer` (after transfer) | Becoming suppressed | Ghost appears where cursor was | Becoming real | Blue hides, red ghost appears |
| E — host just took control | `.host` (after transfer) | Snaps to ghost position | Ghost hides, real cursor | Becoming hidden | Blue reappears |

---

## Known issues worth addressing in a rewrite

1. **Transfer click is injected**: The `mouseDown` that triggers viewer→host control transfer is also injected on the host. Should be consumed.

2. **Watch-only mode cursor handling**: When `inputEnabled=false`, viewer's cursor is still hidden and the blue overlay shown, even though the viewer can never take control. Should show the viewer's real cursor in watch-only mode.

3. **No transfer acknowledgment fence**: Between the viewer sending a `mouseDown` that triggers transfer and receiving the `controlTransfer` packet back, the viewer's subsequent events are in an undefined state. A sequence-number or "pending transfer" flag should block event injection until the round-trip completes.

4. **Keyboard always monitored**: Viewer sends `keyDown`/`keyUp` events unconditionally; host drops them when it has control. Keyboard monitors should only be active (or events only sent) when viewer has control.

5. **Multi-display coordinate mapping**: Both `displayPoint()` and `streamHostCursorToViewer()` hardcode `CGMainDisplayID()`. If the host uses multiple monitors and the cursor is on a secondary display, coordinates will be wrong.

6. **Ghost cursor delta drift**: The suppression tap accumulates deltas to track the ghost. Any missed event (tap timeout/re-enable, warp correction exceeding the 30px guard) can cause the ghost to drift from the true cursor position with no recovery mechanism.

7. **Viewer held-button state not cleared on control transfer**: If viewer has a button held (e.g., mid-drag) when host reclaims, `heldButtons` is not cleared. The host-side drag state becomes inconsistent.

8. **No overlay position smoothing**: Overlay windows update position directly on every UDP packet. Jitter from network or timer variance is visible as overlay flicker.
