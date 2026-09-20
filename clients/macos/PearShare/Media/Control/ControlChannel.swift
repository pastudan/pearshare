import Foundation
import AppKit
import Network
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "ControlChannel")

// MARK: - ControlChannel
//
// Implements the input control state machine described in docs/input-control-spec.md.
//
// State machine (host-side authoritative):
//
//   .hostInControl   — host cursor moves normally; viewer pointer overlay tracks viewer mouse.
//   .viewerInControl — host cursor suppressed (tap active); viewer drives real cursor.
//
// Control transfer rules:
//   • Viewer→Host transfer: triggered by viewer's first mouseDown when host has control AND
//     inputEnabled=true. The triggering click AND its paired mouseUp are NOT injected on the
//     host (they are consumed so the viewer doesn't accidentally click something on the host).
//   • Host→Viewer transfer: triggered by host's physical mouseDown while tap is active.
//     That click is swallowed by the tap (no click on host machine).
//
// K&M sharing toggle (host-side inputEnabled):
//   • Defaults false. Host must explicitly enable via the banner toggle.
//   • When false: viewer cursor is shown normally; overlays are inactive.
//   • When changed: host sends inputStateChanged(enabled:) to viewer so viewer can
//     show/hide cursor management UI without knowing host's inputEnabled state.
//
// Bugs fixed vs previous implementation (see spec for full list):
//   1. Transfer click no longer injected on host.
//   2. Keyboard events only sent/injected when viewer has control.
//   3. Viewer cursor management driven by inputStateChanged — watch-only mode
//      leaves viewer's cursor visible.
//   4. Held mouse buttons released with synthetic mouseUp before control transfer.
//   5. Mouse moves always tracked for pointer overlay regardless of control state.

@MainActor
final class ControlChannel {

    enum Role { case viewer, host }

    // MARK: - Callbacks (set by AppDelegate after start())

    // ── Host-side callbacks ───────────────────────────────────────────────────
    /// Viewer's cursor moved — reposition blue viewer pointer overlay on host screen.
    var onViewerPointerMoved: ((NSPoint) -> Void)?
    /// Host ghost cursor moved (while viewer has control) — reposition red "Me" overlay.
    var onHostGhostMoved: ((NSPoint) -> Void)?

    // ── Viewer-side callbacks ─────────────────────────────────────────────────
    /// Viewer's own cursor moved — reposition blue "Me" overlay on viewer screen.
    var onLocalPointerMoved: ((NSPoint) -> Void)?
    /// Viewer's cursor left the session window boundary.
    var onMouseExitedWindow: (() -> Void)?
    /// Host ghost cursor moved (while viewer has control) — reposition red host overlay.
    var onHostGhostMoved_viewer: ((NSPoint) -> Void)?
    /// K&M sharing was enabled/disabled on the host — activate/deactivate cursor management.
    var onInputModeChanged: ((Bool) -> Void)?

    // ── Both sides ────────────────────────────────────────────────────────────
    /// Control transferred — AppDelegate updates overlays and cursor visibility.
    var onControlStateChanged: ((ControlEvent.Controller) -> Void)?
    /// Peer has ended the session.
    var onHangup: (() -> Void)?
    /// Host only: viewer requests an immediate IDR keyframe.
    var onKeyframeRequested: (() -> Void)?
    /// Viewer only: fired when the viewer clicks inside the session window but the host
    /// has K&M sharing disabled. Used to show a "ask host to enable" hint.
    var onInputBlocked: (() -> Void)?

    // MARK: - Private state

    private let role: Role
    private let port: Int
    private let peerIP: String?

    /// Viewer side: set by AppDelegate so cursor coordinates map to the session window.
    var sessionWindowFrameProvider: (() -> NSRect?)? = nil

    // ── Host-side state ───────────────────────────────────────────────────────
    private var recvListener: NWListener?
    private var peerConnection: NWConnection?
    private var currentController: ControlEvent.Controller = .host
    private var inputEnabled = false
    /// Last known host cursor position (AppKit screen coordinates, updated by monitor or tap).
    private var hostPosition: NSPoint = .zero
    /// Throttle: last time we streamed the host ghost position to viewer.
    private var lastGhostStreamTime: TimeInterval = 0
    /// Buttons held down by the viewer that must be released before a host-reclaim transfer.
    private var viewerHeldButtons: Set<ControlEvent.MouseButton> = []
    /// Last cursor position where the viewer's cursor was, for releasing held buttons.
    private var lastViewerCursorCG: CGPoint = .zero
    private var hostMouseMonitor: Any?
    private let suppressionTap = MouseSuppressionTap()
    private var viewerWatchdog: Timer?

    // ── Viewer-side state ─────────────────────────────────────────────────────
    private var sendConnection: NWConnection?
    private var eventMonitors: [Any] = []
    private var heartbeatTimer: Timer?
    /// Buttons whose mouseDown triggered a control transfer — skip injecting their mouseUp.
    private var skipUpButtons: Set<ControlEvent.MouseButton> = []
    /// Whether the host has K&M sharing enabled (received via inputStateChanged).
    private var inputModeActive = false

    // MARK: - Timing constants

    private static let heartbeatInterval: TimeInterval = 5
    private static let viewerWatchdogTimeout: TimeInterval = 30
    private static let cursorThrottleInterval: TimeInterval = 1.0 / 60.0  // 60 fps

    // MARK: - Init / Start / Stop

    init(role: Role, port: Int, peerIP: String?) {
        self.role = role; self.port = port; self.peerIP = peerIP
    }

    func start() {
        switch role {
        case .host:   startHost()
        case .viewer: startViewer()
        }
    }

    func stop() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        viewerWatchdog?.invalidate();  viewerWatchdog  = nil

        // Nil callbacks before cancelling network so any Tasks already queued on MainActor
        // that fire after stop() are harmless (all callbacks will be nil).
        onViewerPointerMoved = nil; onHostGhostMoved = nil
        onLocalPointerMoved  = nil; onMouseExitedWindow = nil
        onHostGhostMoved_viewer = nil; onInputModeChanged = nil
        onControlStateChanged = nil; onHangup = nil; onKeyframeRequested = nil
        onInputBlocked = nil

        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
        if let m = hostMouseMonitor { NSEvent.removeMonitor(m); hostMouseMonitor = nil }
        suppressionTap.disable()

        sendConnection?.cancel();    sendConnection  = nil
        peerConnection?.cancel();    peerConnection  = nil
        recvListener?.cancel();      recvListener    = nil
    }

    /// Enable or disable K&M sharing. Host-side only.
    /// If disabled while viewer has control, transfers control back to host.
    func setInputEnabled(_ enabled: Bool) {
        guard role == .host else { return }
        guard enabled != inputEnabled else { return }
        inputEnabled = enabled
        if !enabled && currentController == .viewer {
            executeTransfer(to: .host)
        }
        // Tell viewer so it can show/hide cursor management UI.
        send(to: peerConnection, event: .inputStateChanged(enabled: enabled))
    }

    /// Viewer → host: ask for an immediate IDR keyframe (decode error, stalled stream).
    func sendRequestKeyframe() {
        send(to: sendConnection, event: .requestKeyframe)
    }

    /// Send a hangup to the peer before calling stop().
    func sendHangup() {
        let event = ControlEvent.hangup
        switch role {
        case .viewer: send(to: sendConnection, event: event)
        case .host:   send(to: peerConnection, event: event)
        }
    }

    // MARK: ─────────────────────────────────────────────────────────────────────
    // MARK: HOST SIDE
    // MARK: ─────────────────────────────────────────────────────────────────────

    private func startHost() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(
            using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!
        ) else {
            logger.error("ControlChannel host: failed to bind port \(self.port)")
            return
        }
        listener.stateUpdateHandler = { state in
            logger.info("ControlChannel host listener: \(String(describing: state))")
        }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            Task { @MainActor [weak self] in self?.hostAcceptConnection(conn) }
            self?.receiveFromViewer(on: conn)
        }
        listener.start(queue: .global(qos: .userInteractive))
        recvListener = listener
        logger.info("ControlChannel host: listening on port \(self.port)")

        hostPosition = NSEvent.mouseLocation
        installHostMouseMonitor()
        resetViewerWatchdog()

        suppressionTap.onGhostMoved = { [weak self] pos in
            self?.hostPosition = pos
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onHostGhostMoved?(pos)
                self.streamGhostToViewer(pos)
            }
        }
        suppressionTap.onReclaim = { [weak self] in
            Task { @MainActor [weak self] in self?.hostReclaimed() }
        }
    }

    private func hostAcceptConnection(_ conn: NWConnection) {
        peerConnection?.cancel()
        peerConnection = conn
        logger.info("ControlChannel host: viewer connected from \(String(describing: conn.endpoint))")
        // Send current state so viewer UI is correct from the first frame.
        send(to: conn, event: .inputStateChanged(enabled: inputEnabled))
        send(to: conn, event: .controlTransfer(controller: currentController))
    }

    /// Global monitor for host's physical cursor while host has control.
    /// Does NOT run while viewer has control (suppression tap handles that path).
    private func installHostMouseMonitor() {
        hostMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            guard self?.currentController == .host else { return }
            self?.hostPosition = NSEvent.mouseLocation
        }
    }

    private func hostReclaimed() {
        guard currentController == .viewer else { return }
        executeTransfer(to: .host)
    }

    // MARK: - Host: receive viewer events

    nonisolated private func receiveFromViewer(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { logger.error("ControlChannel host recv: \(error)"); return }
            if let data, let event = ControlEvent.from(data: data) {
                Task { @MainActor in self.handleViewerEvent(event) }
            }
            self.receiveFromViewer(on: conn)
        }
    }

    @MainActor
    private func handleViewerEvent(_ event: ControlEvent) {
        switch event {

        case .mouseMoved(let nx, let ny):
            let cgPt  = denormaliseToCG(nx: nx, ny: ny)
            let appPt = cgToAppKit(cgPt)
            lastViewerCursorCG = cgPt
            onViewerPointerMoved?(appPt)
            if currentController == .viewer { moveCursor(to: cgPt) }

        case .mouseButton(let nx, let ny, let button, let down):
            let cgPt = denormaliseToCG(nx: nx, ny: ny)
            lastViewerCursorCG = cgPt

            // Viewer's first click (down) while host has control transfers control.
            // The triggering mouseDown AND its mouseUp are consumed — not injected —
            // so the viewer doesn't accidentally click something on the host machine.
            if down && currentController == .host {
                guard inputEnabled else { break }
                skipUpButtons.insert(button)   // mark this button's up as "skip"
                executeTransfer(to: .viewer)
                return  // do NOT inject the transfer click
            }
            // Suppress the paired mouseUp for a transfer-triggering click.
            if !down && skipUpButtons.contains(button) {
                skipUpButtons.remove(button)
                return
            }
            guard currentController == .viewer else { break }
            if down { viewerHeldButtons.insert(button) } else { viewerHeldButtons.remove(button) }
            injectMouseButton(at: cgPt, button: button, down: down)

        case .scroll(let nx, let ny, let dx, let dy, let precise):
            guard currentController == .viewer else { break }
            injectScroll(at: denormaliseToCG(nx: nx, ny: ny), dx: dx, dy: dy, precise: precise)

        case .keyEvent(let keyCode, let modifiers, let down):
            // Keyboard events are only sent by the viewer when it has control (guarded
            // on the viewer side), but we double-check here for defence-in-depth.
            guard currentController == .viewer else { break }
            injectKey(keyCode: keyCode, modifiers: modifiers, down: down)

        case .hangup:
            logger.info("ControlChannel host: viewer sent hangup")
            viewerWatchdog?.invalidate(); viewerWatchdog = nil
            onHangup?()

        case .heartbeat:
            resetViewerWatchdog()

        case .requestKeyframe:
            onKeyframeRequested?()

        default:
            break  // controlTransfer, hostCursorMoved, inputStateChanged — host never receives these
        }
    }

    // MARK: - Host: control transfer

    private func executeTransfer(to newController: ControlEvent.Controller) {
        guard newController != currentController else { return }
        logger.info("ControlChannel host: control → \(newController.rawValue)")

        if newController == .viewer {
            NSApp.activate(ignoringOtherApps: true)
            suppressionTap.enable(initialPosition: hostPosition)
        } else {
            // Release any buttons the viewer was holding before giving control back,
            // so the host machine doesn't end up with phantom mouse buttons stuck down.
            for btn in viewerHeldButtons {
                injectMouseButton(at: lastViewerCursorCG, button: btn, down: false)
            }
            viewerHeldButtons.removeAll()
            skipUpButtons.removeAll()

            // Warp cursor to host's tracked position so the transition is seamless.
            let screenH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
            CGWarpMouseCursorPosition(CGPoint(x: hostPosition.x, y: screenH - hostPosition.y))
            suppressionTap.disable()
        }

        currentController = newController
        send(to: peerConnection, event: .controlTransfer(controller: newController))
        onControlStateChanged?(newController)
    }

    // MARK: - Host: ghost streaming

    private func streamGhostToViewer(_ pos: NSPoint) {
        guard currentController == .viewer else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastGhostStreamTime >= Self.cursorThrottleInterval else { return }
        lastGhostStreamTime = now
        let w = CGFloat(CGDisplayPixelsWide(CGMainDisplayID()))
        let h = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        guard w > 0, h > 0 else { return }
        let nx = Double(max(0, min(1, (pos.x) / w)))
        let ny = Double(max(0, min(1, 1.0 - (pos.y / h))))
        send(to: peerConnection, event: .hostCursorMoved(x: nx, y: ny))
    }

    // MARK: - Host: viewer watchdog

    private func resetViewerWatchdog() {
        viewerWatchdog?.invalidate()
        viewerWatchdog = Timer.scheduledTimer(
            withTimeInterval: Self.viewerWatchdogTimeout, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                logger.info("ControlChannel host: viewer watchdog fired — no heartbeat")
                self.onHangup?()
            }
        }
    }

    // MARK: ─────────────────────────────────────────────────────────────────────
    // MARK: VIEWER SIDE
    // MARK: ─────────────────────────────────────────────────────────────────────

    private func startViewer() {
        guard let ip = peerIP else { return }
        let conn = NWConnection(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .udp
        )
        conn.stateUpdateHandler = { [weak self] state in
            logger.info("ControlChannel viewer UDP: \(String(describing: state))")
            if case .ready = state {
                Task { @MainActor [weak self] in self?.send(to: self?.sendConnection, event: .requestKeyframe) }
            }
        }
        conn.start(queue: .global(qos: .userInteractive))
        sendConnection = conn
        receiveFromHost(on: conn)
        installViewerEventMonitors()

        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.send(to: self?.sendConnection, event: .heartbeat) }
        }
    }

    // MARK: - Viewer: receive host events

    nonisolated private func receiveFromHost(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { logger.error("ControlChannel viewer recv: \(error)"); return }
            if let data, let event = ControlEvent.from(data: data) {
                Task { @MainActor in self.handleHostEvent(event) }
            }
            self.receiveFromHost(on: conn)
        }
    }

    @MainActor
    private func handleHostEvent(_ event: ControlEvent) {
        switch event {
        case .controlTransfer(let controller):
            logger.info("ControlChannel viewer: control → \(controller.rawValue)")
            viewerKnowsItHasControl = (controller == .viewer)
            onControlStateChanged?(controller)

        case .hostCursorMoved(let nx, let ny):
            onHostGhostMoved_viewer?(denormaliseToScreen(nx: nx, ny: ny))

        case .inputStateChanged(let enabled):
            logger.info("ControlChannel viewer: inputMode → \(enabled)")
            inputModeActive = enabled
            onInputModeChanged?(enabled)

        case .hangup:
            logger.info("ControlChannel viewer: host sent hangup")
            onHangup?()

        default:
            break  // viewer never receives mouseMoved, keyEvent, etc.
        }
    }

    // MARK: - Viewer: event monitors

    private func installViewerEventMonitors() {
        var lastMoveSent: TimeInterval = 0
        var wasInsideWindow = false
        var leftHeld = false
        var rightHeld = false

        func addLocal(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in
                handler(e); return e
            }) { eventMonitors.append(m) }
        }

        func sendCursorUpdate() {
            let now = Date().timeIntervalSinceReferenceDate
            guard now - lastMoveSent >= Self.cursorThrottleInterval else { return }
            lastMoveSent = now
            let pt = NSEvent.mouseLocation
            onLocalPointerMoved?(pt)
            let (nx, ny) = normalise(screenPoint: pt)
            send(to: sendConnection, event: .mouseMoved(x: nx, y: ny))
        }

        // Mouse moves — always forwarded (drives pointer overlay regardless of who has control).
        addLocal(.mouseMoved) { [weak self] _ in
            guard let self else { return }
            let inside = self.isInsideWindow()
            if !inside {
                if wasInsideWindow { wasInsideWindow = false; self.onMouseExitedWindow?() }
                return
            }
            wasInsideWindow = true
            sendCursorUpdate()
        }

        // Drag events — forward cursor position so the host tracks drags correctly.
        addLocal(.leftMouseDown) { [weak self] _ in
            guard let self, self.isInsideWindow() else { return }
            if !self.inputModeActive { self.onInputBlocked?(); return }
            leftHeld = true
            self.sendButton(.left, down: true)
        }
        addLocal(.leftMouseUp) { [weak self] _ in
            let wasHeld = leftHeld; leftHeld = false
            guard self?.isInsideWindow() == true || wasHeld else { return }
            self?.sendButton(.left, down: false)
        }
        addLocal(.rightMouseDown) { [weak self] _ in
            guard let self, self.isInsideWindow() else { return }
            if !self.inputModeActive { self.onInputBlocked?(); return }
            rightHeld = true
            self.sendButton(.right, down: true)
        }
        addLocal(.rightMouseUp) { [weak self] _ in
            let wasHeld = rightHeld; rightHeld = false
            guard self?.isInsideWindow() == true || wasHeld else { return }
            self?.sendButton(.right, down: false)
        }
        addLocal([.leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            guard let self, leftHeld || rightHeld || self.isInsideWindow() else { return }
            sendCursorUpdate()
        }
        addLocal(.scrollWheel) { [weak self] e in
            guard self?.isInsideWindow() == true else { return }
            self?.sendScroll(e)
        }

        // Keyboard — ONLY forwarded when viewer has control.
        // Guarded on the viewer side to avoid wasteful sends; host also guards defensively.
        addLocal(.keyDown) { [weak self] e in
            guard self?.viewerKnowsItHasControl == true else { return }
            self?.send(to: self?.sendConnection, event: .keyEvent(
                keyCode: e.keyCode,
                modifiers: UInt64(e.modifierFlags.rawValue),
                down: true
            ))
        }
        addLocal(.keyUp) { [weak self] e in
            guard self?.viewerKnowsItHasControl == true else { return }
            self?.send(to: self?.sendConnection, event: .keyEvent(
                keyCode: e.keyCode,
                modifiers: UInt64(e.modifierFlags.rawValue),
                down: false
            ))
        }
    }

    /// True when the viewer has received controlTransfer(.viewer) from the host
    /// and has not yet received controlTransfer(.host). Updated in handleHostEvent.
    private var viewerKnowsItHasControl = false

    // MARK: - Viewer: send helpers

    private func sendButton(_ button: ControlEvent.MouseButton, down: Bool) {
        let (nx, ny) = normalise(screenPoint: NSEvent.mouseLocation)
        send(to: sendConnection, event: .mouseButton(x: nx, y: ny, button: button, down: down))
    }

    private func sendScroll(_ e: NSEvent) {
        let (nx, ny) = normalise(screenPoint: NSEvent.mouseLocation)
        send(to: sendConnection, event: .scroll(
            x: nx, y: ny,
            dx: Double(e.scrollingDeltaX),
            dy: Double(e.scrollingDeltaY),
            precise: e.hasPreciseScrollingDeltas
        ))
    }

    // MARK: - Viewer: coordinate helpers

    private func isInsideWindow() -> Bool {
        guard let frame = sessionWindowFrameProvider?() else { return false }
        return frame.contains(NSEvent.mouseLocation)
    }

    private func normalise(screenPoint pt: NSPoint) -> (x: Double, y: Double) {
        let frame: NSRect
        if let f = sessionWindowFrameProvider?() { frame = f }
        else if let s = NSScreen.main           { frame = s.frame }
        else                                     { return (0.5, 0.5) }
        guard frame.width > 0, frame.height > 0 else { return (0.5, 0.5) }
        let nx = Double(max(0, min(1, (pt.x - frame.origin.x) / frame.width)))
        let ny = Double(max(0, min(1, 1.0 - (pt.y - frame.origin.y) / frame.height)))
        return (nx, ny)
    }

    /// Convert normalised [0,1] host-display coords to a screen point within the session window.
    private func denormaliseToScreen(nx: Double, ny: Double) -> NSPoint {
        let frame: NSRect
        if let f = sessionWindowFrameProvider?() { frame = f }
        else if let s = NSScreen.main            { frame = s.frame }
        else                                      { return .zero }
        return NSPoint(
            x: frame.origin.x + CGFloat(nx)       * frame.width,
            y: frame.origin.y + CGFloat(1.0 - ny) * frame.height
        )
    }

    // MARK: ─────────────────────────────────────────────────────────────────────
    // MARK: HOST: CGEvent injection
    // MARK: ─────────────────────────────────────────────────────────────────────

    // A dedicated CGEventSource whose userData matches eventTag so the suppression tap
    // can identify injected events and let them pass through without treating them as
    // physical HID events (which would corrupt ghost delta tracking or trigger reclaim).
    private static let injectionSource: CGEventSource = {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            fatalError("CGEventSource unavailable")
        }
        src.userData = MouseSuppressionTap.eventTag
        return src
    }()

    private func post(_ event: CGEvent) {
        event.post(tap: CGEventTapLocation(rawValue: 1)!)  // kCGSessionEventTap
    }

    // HOST: coordinate helpers

    private func denormaliseToCG(nx: Double, ny: Double) -> CGPoint {
        let w = CGFloat(CGDisplayPixelsWide(CGMainDisplayID()))
        let h = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return CGPoint(x: nx * w, y: ny * h)
    }

    private func cgToAppKit(_ pt: CGPoint) -> NSPoint {
        let h = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return NSPoint(x: pt.x, y: h - pt.y)
    }

    // Buttons currently held by the viewer (for correct drag event injection).
    private var heldButtons: Set<CGMouseButton> = []

    private func moveCursor(to pt: CGPoint) {
        // Keep the tap's frozen position in sync so warp-snap always returns here.
        suppressionTap.frozenCursorPosition = pt

        if heldButtons.contains(.left) {
            if let e = CGEvent(mouseEventSource: Self.injectionSource,
                               mouseType: .leftMouseDragged,
                               mouseCursorPosition: pt, mouseButton: .left) {
                post(e); return
            }
        } else if heldButtons.contains(.right) {
            if let e = CGEvent(mouseEventSource: Self.injectionSource,
                               mouseType: .rightMouseDragged,
                               mouseCursorPosition: pt, mouseButton: .right) {
                post(e); return
            }
        }
        CGWarpMouseCursorPosition(pt)
    }

    private func injectMouseButton(at pt: CGPoint, button: ControlEvent.MouseButton, down: Bool) {
        let (cgBtn, downType, upType): (CGMouseButton, CGEventType, CGEventType)
        switch button {
        case .left:  (cgBtn, downType, upType) = (.left,   .leftMouseDown,  .leftMouseUp)
        case .right: (cgBtn, downType, upType) = (.right,  .rightMouseDown, .rightMouseUp)
        case .other: (cgBtn, downType, upType) = (.center, .otherMouseDown, .otherMouseUp)
        }
        if down { heldButtons.insert(cgBtn) } else { heldButtons.remove(cgBtn) }
        CGWarpMouseCursorPosition(pt)
        guard let e = CGEvent(mouseEventSource: Self.injectionSource,
                              mouseType: down ? downType : upType,
                              mouseCursorPosition: pt, mouseButton: cgBtn) else { return }
        post(e)
    }

    private func injectScroll(at pt: CGPoint, dx: Double, dy: Double, precise: Bool) {
        if precise {
            guard let e = CGEvent(scrollWheelEvent2Source: Self.injectionSource, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(dy.rounded()),
                                  wheel2: Int32(dx.rounded()),
                                  wheel3: 0) else { return }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(dy * 65536))
            e.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64(dx * 65536))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,   value: Int64(dy.rounded()))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2,   value: Int64(dx.rounded()))
            e.location = pt
            post(e)
        } else {
            guard let e = CGEvent(scrollWheelEvent2Source: Self.injectionSource, units: .line,
                                  wheelCount: 2,
                                  wheel1: Int32(dy.rounded()),
                                  wheel2: Int32(dx.rounded()),
                                  wheel3: 0) else { return }
            e.location = pt; post(e)
        }
    }

    private func injectKey(keyCode: UInt16, modifiers: UInt64, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: Self.injectionSource,
                              virtualKey: keyCode, keyDown: down) else { return }
        e.flags = CGEventFlags(rawValue: modifiers)
        post(e)
    }

    // MARK: - Shared send helper

    private func send(to conn: NWConnection?, event: ControlEvent) {
        guard let data = event.toData(), let conn else { return }
        conn.send(content: data, completion: .idempotent)
    }
}

// MARK: - MouseSuppressionTap ─────────────────────────────────────────────────
//
// Intercepts physical mouse events at the HID level when viewer has control.
// Physical mouse movement is suppressed (system cursor frozen); the host's
// real position is tracked via raw deltas as a "ghost".
// Injected events tagged with `eventTag` are passed through unchanged.

private final class MouseSuppressionTap {

    static let eventTag: Int64 = 0x50454152  // "PEAR"

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var ghostPosition: NSPoint = .zero
    /// CG-coordinate position the cursor is snapped back to on every physical mouse move.
    /// Initialised to the host cursor position at transfer time; updated by moveCursor()
    /// so it always matches wherever the viewer last drove the cursor.
    var frozenCursorPosition: CGPoint = .zero

    var onGhostMoved: ((NSPoint) -> Void)?
    var onReclaim: (() -> Void)?

    func enable(initialPosition: NSPoint) {
        guard tap == nil else { return }
        ghostPosition = initialPosition
        // Seed the frozen position in CG coords (top-left origin) from the AppKit point.
        let screenH = NSScreen.main?.frame.height ?? 900
        frozenCursorPosition = CGPoint(x: initialPosition.x, y: screenH - initialPosition.y)

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: MouseSuppressionTap.callback,
            userInfo: selfPtr
        ) else {
            logger.error("MouseSuppressionTap: failed to create (Accessibility permission required)")
            return
        }

        tap = newTap
        let src = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        // Decouple cursor from mouse at the display-driver level so the trackpad
        // cannot advance the system cursor position while the tap is active.
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        logger.info("MouseSuppressionTap: enabled at \(initialPosition.x), \(initialPosition.y)")
    }

    func disable() {
        guard tap != nil else { return }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; runLoopSource = nil
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        logger.info("MouseSuppressionTap: disabled")
    }

    deinit { disable() }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<MouseSuppressionTap>.fromOpaque(userInfo).takeUnretainedValue()

        // macOS auto-disables event taps for two reasons; handle both.
        // Without this, the tap dies permanently after the first modifier keypress,
        // Space switch, screen lock, etc., and cursor suppression stops working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap.tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Tagged injected events must not re-enter the tap — pass through immediately.
        if event.getIntegerValueField(.eventSourceUserData) == MouseSuppressionTap.eventTag {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
            let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))

            // Filter out warp-correction events: after CGWarpMouseCursorPosition the system
            // generates one large-delta HID event. Real trackpad/mouse events are always
            // small (< 30 px per poll at 60–120 Hz); warp corrections are typically 50–600 px.
            guard abs(dx) + abs(dy) <= 30 else { return nil }

            var pos = tap.ghostPosition
            pos.x += dx; pos.y -= dy
            if let screen = NSScreen.main?.frame {
                pos.x = max(screen.minX, min(screen.maxX, pos.x))
                pos.y = max(screen.minY, min(screen.maxY, pos.y))
            }
            tap.ghostPosition = pos
            tap.onGhostMoved?(pos)
            // Snap cursor back to the frozen position (wherever the viewer last drove it).
            // This works even when CGAssociateMouseAndMouseCursorPosition is ineffective
            // (e.g. PearShare not in the foreground as an .accessory app).
            // The resulting large-delta warp-correction event is caught by the guard above.
            CGWarpMouseCursorPosition(tap.frozenCursorPosition)
            return nil  // suppress — don't move system cursor

        case .leftMouseDown, .rightMouseDown:
            tap.onReclaim?()
            return nil  // swallow the reclaim click

        case .leftMouseUp, .rightMouseUp:
            return nil  // swallow all physical mouse-up events while active

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
