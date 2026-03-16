import Foundation
import AppKit
import Network
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "ControlChannel")

// MARK: - ControlChannel
//
// Multiplayer cursor model:
//
//   Host side  — listens on UDP port 5537.
//     • Always tracks viewer's cursor position → fires onRemoteCursorMoved (for blue overlay).
//     • Injects viewer's movements as CGEvents only when currentController == .viewer.
//     • Monitors its own local mouse; fires onHostCursorMoved so AppDelegate can show the
//       host's red "ghost" overlay when viewer has control.
//     • When a viewer mouseDown arrives and controller is .host → transfer to .viewer,
//       enable CGEventTap to suppress physical mouse, notify viewer via peerConnection.
//     • When a host physical mouseDown is intercepted by the tap → transfer to .host,
//       disable CGEventTap, notify viewer.
//     • Injected CGEvents are tagged with eventSourceUserData so the tap lets them through.
//
//   Viewer side — connects to host's UDP port 5537 (bidirectional).
//     • Sends mouseMoved / mouseButton / scroll / keyEvent events to host.
//     • Listens on the same connection for incoming controlTransfer packets from host.
//     • Fires onControlTransfer so AppDelegate can show/hide the viewer's local blue overlay.
//     • Fires onLocalCursorMoved with the viewer's screen-space cursor position so AppDelegate
//       can reposition the viewer's local blue overlay.

@MainActor
final class ControlChannel {

    enum Role { case viewer, host }

    // MARK: - Shared callbacks (set by AppDelegate after start())

    /// Host: viewer's cursor moved — reposition viewer's blue overlay.
    var onRemoteCursorMoved: ((NSPoint) -> Void)?
    /// Host: host's own physical cursor moved while viewer has control — reposition red ghost overlay.
    var onHostCursorMoved: ((NSPoint) -> Void)?
    /// Both sides: control transferred — AppDelegate shows/hides overlays accordingly.
    var onControlTransfer: ((ControlEvent.Controller) -> Void)?
    /// Viewer: local cursor moved — AppDelegate repositions viewer's local blue overlay.
    var onLocalCursorMoved: ((NSPoint) -> Void)?
    /// Viewer: cursor just left the session window boundary.
    var onMouseExitedWindow: (() -> Void)?
    /// Viewer: host's ghost cursor moved while viewer has control — show red overlay on viewer screen.
    var onRemoteHostCursorMoved: ((NSPoint) -> Void)?
    /// Both sides: peer has ended the session (hangup event received, or host watchdog fired).
    var onHangup: (() -> Void)?

    // MARK: - Private state

    private let role: Role
    private let port: Int
    private let peerIP: String?

    /// Viewer side: set by AppDelegate so coordinates are normalised to the session window.
    var sessionWindowFrameProvider: (() -> NSRect?)? = nil

    // Viewer side
    private var sendConnection: NWConnection?
    private var eventMonitors: [Any] = []

    // Host side: throttle for host→viewer ghost cursor updates
    private var lastHostCursorSent: TimeInterval = 0

    // Host side
    private var recvListener: NWListener?
    /// The NWConnection to the viewer — stored so host can send controlTransfer back.
    private var peerConnection: NWConnection?
    /// Who currently drives the system cursor.
    private var currentController: ControlEvent.Controller = .host
    /// Persistent absolute position of the host's cursor (independent of the system cursor).
    private var hostPosition: NSPoint = .zero
    /// Tracks host's physical mouse while host has control so hostPosition stays current.
    private var hostMouseMonitor: Any?
    /// Fallback global monitor for host reclaim click (in case the tap misses).
    private var hostMouseDownMonitor: Any?
    /// CGEventTap that suppresses host's physical mouse while viewer has control.
    /// Injected events are tagged so the tap lets them through.
    private let suppressionTap = MouseSuppressionTap()
    /// Host side: fires if no heartbeat arrives within the inactivity window.
    private var viewerWatchdogTimer: Timer?
    /// Viewer side: sends periodic heartbeat to host so the watchdog stays alive.
    private var heartbeatTimer: Timer?

    private static let heartbeatInterval: TimeInterval = 5
    private static let viewerInactivityTimeout: TimeInterval = 30

    // MARK: - Init

    init(role: Role, port: Int, peerIP: String?) {
        self.role = role
        self.port = port
        self.peerIP = peerIP
    }

    // MARK: - Start / Stop

    func start() {
        switch role {
        case .viewer: startViewerSide()
        case .host:   startHostSide()
        }
    }

    /// Send a hangup event to the peer, then clean up. Must be called before stop().
    func sendHangup() {
        send(.hangup)
    }

    func stop() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        viewerWatchdogTimer?.invalidate(); viewerWatchdogTimer = nil

        for m in eventMonitors { NSEvent.removeMonitor(m) }
        eventMonitors.removeAll()
        if let m = hostMouseMonitor     { NSEvent.removeMonitor(m); hostMouseMonitor = nil }
        if let m = hostMouseDownMonitor { NSEvent.removeMonitor(m); hostMouseDownMonitor = nil }
        suppressionTap.disable()

        sendConnection?.cancel()
        sendConnection = nil
        peerConnection = nil
        recvListener?.cancel()
        recvListener = nil
    }

    // MARK: - VIEWER SIDE ─────────────────────────────────────────────────────────

    private func startViewerSide() {
        guard let ip = peerIP else { return }
        let conn = NWConnection(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .udp
        )
        conn.stateUpdateHandler = { state in
            logger.info("ControlChannel viewer UDP \(String(describing: state))")
        }
        conn.start(queue: .global(qos: .userInteractive))
        self.sendConnection = conn

        // Listen on the same connection for controlTransfer packets sent by the host.
        receiveFromHost(on: conn)
        installEventMonitors()
    }

    /// Receive loop for host→viewer messages on the viewer's outbound connection.
    nonisolated private func receiveFromHost(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { logger.error("ControlChannel viewer recv error: \(error)"); return }
            if let data, let event = ControlEvent.from(data: data) {
                Task { @MainActor in self.handleViewerIncoming(event) }
            }
            self.receiveFromHost(on: connection)
        }
    }

    @MainActor
    private func handleViewerIncoming(_ event: ControlEvent) {
        switch event {
        case .controlTransfer(let controller):
            logger.info("ControlChannel viewer: control transferred to \(controller.rawValue)")
            onControlTransfer?(controller)
        case .hostCursorMoved(let nx, let ny):
            onRemoteHostCursorMoved?(denormalise(nx: nx, ny: ny))
        default:
            break
        }
    }

    /// Convert normalised [0,1] host-display coordinates to a screen point within
    /// the viewer's session window. Mirrors the normalise() convention (top-left origin).
    private func denormalise(nx: Double, ny: Double) -> NSPoint {
        let frame: NSRect
        if let f = sessionWindowFrameProvider?() { frame = f }
        else if let s = NSScreen.main            { frame = s.frame }
        else                                      { return .zero }
        return NSPoint(
            x: frame.origin.x + CGFloat(nx) * frame.width,
            y: frame.origin.y + CGFloat(1.0 - ny) * frame.height
        )
    }

    // MARK: - Viewer event monitors

    private func installEventMonitors() {
        func addLocal(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in
                handler(e); return e
            }) { eventMonitors.append(m) }
        }

        var lastMoveSent: TimeInterval = 0
        var wasInsideWindow = false

        // Shared cursor-update logic used by both mouseMoved and drag events.
        func sendCursorUpdate(to self: ControlChannel) {
            let now = Date().timeIntervalSinceReferenceDate
            guard now - lastMoveSent > 0.016 else { return }
            lastMoveSent = now
            let pt = NSEvent.mouseLocation
            self.onLocalCursorMoved?(pt)
            let (x, y) = self.normalise(screenPoint: pt)
            self.send(.mouseMoved(x: x, y: y))
        }

        addLocal(.mouseMoved) { [weak self] _ in
            guard let self else { return }
            let inside = self.isMouseInsideWindow()
            if !inside {
                if wasInsideWindow {
                    wasInsideWindow = false
                    self.onMouseExitedWindow?()
                }
                return
            }
            wasInsideWindow = true
            sendCursorUpdate(to: self)
        }

        // Drag events: forward cursor position so the host tracks the pointer during a drag.
        // Without these, the host sees mouseDown + mouseUp with no movement in between,
        // breaking click-drag operations (file moves, text selection, resizing, etc.)
        // Track which buttons are currently held so drag events continue even when
        // the cursor leaves the session window bounds mid-drag (e.g. dragging a host
        // window to the edge of the session view).
        var leftHeld = false
        var rightHeld = false

        addLocal(.leftMouseDown) { [weak self] _ in
            guard self?.isMouseInsideWindow() == true else { return }
            leftHeld = true
            self?.sendButton(.left, down: true)
        }
        addLocal(.leftMouseUp) { [weak self] _ in
            let wasHeld = leftHeld
            leftHeld = false
            // Always send mouseUp to release a drag even if the cursor drifted outside.
            guard self?.isMouseInsideWindow() == true || wasHeld else { return }
            self?.sendButton(.left, down: false)
        }
        addLocal(.rightMouseDown) { [weak self] _ in
            guard self?.isMouseInsideWindow() == true else { return }
            rightHeld = true
            self?.sendButton(.right, down: true)
        }
        addLocal(.rightMouseUp) { [weak self] _ in
            let wasHeld = rightHeld
            rightHeld = false
            guard self?.isMouseInsideWindow() == true || wasHeld else { return }
            self?.sendButton(.right, down: false)
        }

        // Forward drag cursor updates; continue even when the cursor leaves the window
        // (the user may drag a host window all the way to the edge of the session view).
        addLocal([.leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            guard let self, leftHeld || rightHeld || self.isMouseInsideWindow() else { return }
            sendCursorUpdate(to: self)
        }
        addLocal(.scrollWheel)    { [weak self] e  in guard self?.isMouseInsideWindow() == true else { return }; self?.sendScrollEvent(e) }

        addLocal(.keyDown) { [weak self] e in self?.sendKey(e, down: true)  }
        addLocal(.keyUp)   { [weak self] e in self?.sendKey(e, down: false) }
    }

    private func isMouseInsideWindow() -> Bool {
        guard let frame = sessionWindowFrameProvider?() else { return false }
        return frame.contains(NSEvent.mouseLocation)
    }

    private func normalise(screenPoint: NSPoint) -> (x: Double, y: Double) {
        let frame: NSRect
        if let f = sessionWindowFrameProvider?() { frame = f }
        else if let s = NSScreen.main           { frame = s.frame }
        else                                     { return (0.5, 0.5) }
        guard frame.width > 0, frame.height > 0 else { return (0.5, 0.5) }
        let nx = max(0, min(1, Double((screenPoint.x - frame.origin.x) / frame.width)))
        let ny = max(0, min(1, Double(1.0 - (screenPoint.y - frame.origin.y) / frame.height)))
        return (nx, ny)
    }

    // MARK: - Viewer send helpers

    private func sendButton(_ button: ControlEvent.MouseButton, down: Bool) {
        let (x, y) = normalise(screenPoint: NSEvent.mouseLocation)
        send(.mouseButton(x: x, y: y, button: button, down: down))
    }

    private func sendScrollEvent(_ event: NSEvent) {
        let (x, y) = normalise(screenPoint: NSEvent.mouseLocation)
        send(.scroll(x: x, y: y, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY)))
    }

    private func sendKey(_ event: NSEvent, down: Bool) {
        send(.keyEvent(keyCode: event.keyCode, modifiers: UInt64(event.modifierFlags.rawValue), down: down))
    }

    private func send(_ event: ControlEvent) {
        guard let data = event.toData(), let conn = sendConnection else { return }
        conn.send(content: data, completion: .idempotent)
    }

    // MARK: - HOST SIDE ───────────────────────────────────────────────────────────

    private func startHostSide() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params,
                                              on: NWEndpoint.Port(rawValue: UInt16(port))!) else {
            logger.error("ControlChannel host: failed to bind port \(self.port)")
            return
        }
        listener.stateUpdateHandler = { state in
            logger.info("ControlChannel host listener \(String(describing: state))")
        }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            guard let self else { return }
            Task { @MainActor in
                self.peerConnection = conn
                // Tell the viewer the current controller immediately so their
                // overlay and cursor state is correct from the first frame.
                if let data = ControlEvent.controlTransfer(controller: self.currentController).toData() {
                    conn.send(content: data, completion: .idempotent)
                }
            }
            self.receiveFromViewer(on: conn)
        }
        listener.start(queue: .global(qos: .userInteractive))
        self.recvListener = listener
        logger.info("ControlChannel host: listening on port \(self.port)")

        hostPosition = NSEvent.mouseLocation
        installHostMouseMonitors()

        suppressionTap.onGhostMoved = { [weak self] pos in
            self?.hostPosition = pos
            Task { @MainActor in
                self?.onHostCursorMoved?(pos)
                self?.streamHostCursorToViewer(pos)
            }
        }
        suppressionTap.onReclaim = { [weak self] in
            Task { @MainActor in self?.hostDidClick() }
        }
    }

    /// Global monitors for the host's physical cursor.
    /// The move monitor must guard on currentController == .host because tagged injected
    /// events (from the viewer) also pass through the tap and reach NSEvent monitors —
    /// without the guard, hostPosition would be overwritten with the viewer's position.
    /// The mouseDown monitor is a fallback for reclaim if the tap misses.
    private func installHostMouseMonitors() {
        hostMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            guard self?.currentController == .host else { return }
            self?.hostPosition = NSEvent.mouseLocation
        }

        hostMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // Tagged events are injected viewer clicks that passed through the suppression tap.
            // Never treat them as a host reclaim — that would bounce control back immediately.
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == MouseSuppressionTap.eventTag { return }
            Task { @MainActor in self?.hostDidClick() }
        }
    }

    @MainActor
    private func hostDidClick() {
        guard currentController == .viewer else { return }
        transferControl(to: .host)
    }

    /// Stream the host's ghost cursor position to the viewer at ≤60 fps while viewer has control.
    /// Coordinates are normalised [0,1] relative to the host's main display (top-left origin).
    @MainActor
    private func streamHostCursorToViewer(_ pos: NSPoint) {
        guard currentController == .viewer else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastHostCursorSent > 0.016 else { return }
        lastHostCursorSent = now
        guard let screen = NSScreen.main else { return }
        let nx = Double(max(0, min(1, (pos.x - screen.frame.minX) / screen.frame.width)))
        let ny = Double(max(0, min(1, 1.0 - (pos.y - screen.frame.minY) / screen.frame.height)))
        if let data = ControlEvent.hostCursorMoved(x: nx, y: ny).toData() {
            peerConnection?.send(content: data, completion: .idempotent)
        }
    }

    // MARK: - Host receive loop

    nonisolated private func receiveFromViewer(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { logger.error("ControlChannel host recv error: \(error)"); return }
            if let data, let event = ControlEvent.from(data: data) {
                Task { @MainActor in self.handleViewerEvent(event) }
            }
            self.receiveFromViewer(on: connection)
        }
    }

    @MainActor
    private func handleViewerEvent(_ event: ControlEvent) {
        switch event {
        case .mouseMoved(let nx, let ny):
            let cgPt   = displayPoint(nx: nx, ny: ny)
            let appKit = cgPointToAppKit(cgPt)
            onRemoteCursorMoved?(appKit)
            if currentController == .viewer { moveCGCursor(to: cgPt) }

        case .mouseButton(let nx, let ny, let button, let down):
            let cgPt = displayPoint(nx: nx, ny: ny)
            // First viewer click transfers control; subsequent clicks are injected normally.
            if down && currentController == .host {
                transferControl(to: .viewer)
            }
            if currentController == .viewer {
                injectMouseButton(at: cgPt, button: button, down: down)
            }

        case .scroll(let nx, let ny, let dx, let dy):
            if currentController == .viewer {
                injectScroll(at: displayPoint(nx: nx, ny: ny), dx: dx, dy: dy)
            }

        case .keyEvent(let keyCode, let modifiers, let down):
            if currentController == .viewer {
                injectKey(keyCode: keyCode, modifiers: modifiers, down: down)
            }

        case .controlTransfer, .hostCursorMoved:
            break  // host only sends these; viewer should never send them

        case .hangup:
            break  // handled upstream in receiveFromViewer before this switch

        case .heartbeat:
            break  // handled upstream (watchdog timer reset)
        }
    }

    // MARK: - Control transfer

    @MainActor
    private func transferControl(to newController: ControlEvent.Controller) {
        guard newController != currentController else { return }
        currentController = newController
        logger.info("ControlChannel host: control → \(newController.rawValue)")

        if newController == .viewer {
            // CGAssociateMouseAndMouseCursorPosition(false) requires the calling process to be
            // the active (frontmost) application. NSApp.activate is synchronous — it makes us
            // active before the next line runs, so the CGAssociate call in suppressionTap.enable()
            // takes effect. The association setting persists even after we lose focus again.
            NSApp.activate(ignoringOtherApps: true)
            suppressionTap.enable(initialPosition: hostPosition)
        } else {
            // Warp the system cursor to the host's tracked position so the host
            // continues from their own position, not from the viewer's.
            let screenH = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
            CGWarpMouseCursorPosition(CGPoint(x: hostPosition.x, y: screenH - hostPosition.y))
            suppressionTap.disable()
        }

        if let data = ControlEvent.controlTransfer(controller: newController).toData() {
            peerConnection?.send(content: data, completion: .idempotent)
        }

        onControlTransfer?(newController)
    }

    // MARK: - Coordinate helpers (host)

    private func displayPoint(nx: Double, ny: Double) -> CGPoint {
        let w = CGFloat(CGDisplayPixelsWide(CGMainDisplayID()))
        let h = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return CGPoint(x: nx * w, y: ny * h)
    }

    private func cgPointToAppKit(_ pt: CGPoint) -> NSPoint {
        let h = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return NSPoint(x: pt.x, y: h - pt.y)
    }

    // Tracks which mouse buttons the viewer currently holds down so moveCGCursor can
    // inject leftMouseDragged / rightMouseDragged events (rather than a silent warp)
    // while a drag is in progress — this is what makes host apps actually track the drag.
    private var heldButtons: Set<CGMouseButton> = []

    // MARK: - CGEvent injection (host)

    // A dedicated CGEventSource whose userData == eventTag.
    // Using a proper source (rather than setting the field post-hoc on a nil-source event)
    // ensures the tag survives the event pipeline and is reliably readable in NSEvent monitors.
    // Events are posted at .cgsessionEventTap — downstream of our HID suppression tap —
    // so injected events can never re-enter the tap and corrupt the ghost position delta math.
    private static let injectionSource: CGEventSource = {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            fatalError("CGEventSource unavailable")
        }
        src.userData = MouseSuppressionTap.eventTag
        return src
    }()

    private func postInjected(_ event: CGEvent) {
        // kCGSessionEventTap (rawValue 1) is downstream of our HID suppression tap,
        // so injected events never re-enter the tap and corrupt the ghost position delta math.
        event.post(tap: CGEventTapLocation(rawValue: 1)!)
    }

    private func moveCGCursor(to pt: CGPoint) {
        // While a button is held we must inject a dragged event (not just warp) so that
        // host apps (Finder, windows, etc.) actually receive a drag and track it.
        // When no button is held, CGWarpMouseCursorPosition is used because injecting a
        // mouseMoved CGEvent synthesises a HID-level event whose large delta would corrupt
        // the ghost position accumulation in the suppression tap.
        if heldButtons.contains(.left) {
            if let e = CGEvent(mouseEventSource: Self.injectionSource,
                               mouseType: .leftMouseDragged,
                               mouseCursorPosition: pt, mouseButton: .left) {
                postInjected(e)
                return
            }
        } else if heldButtons.contains(.right) {
            if let e = CGEvent(mouseEventSource: Self.injectionSource,
                               mouseType: .rightMouseDragged,
                               mouseCursorPosition: pt, mouseButton: .right) {
                postInjected(e)
                return
            }
        }
        CGWarpMouseCursorPosition(pt)
    }

    private func injectMouseButton(at pt: CGPoint, button: ControlEvent.MouseButton, down: Bool) {
        let (cgButton, downType, upType): (CGMouseButton, CGEventType, CGEventType)
        switch button {
        case .left:  (cgButton, downType, upType) = (.left,  .leftMouseDown,  .leftMouseUp)
        case .right: (cgButton, downType, upType) = (.right, .rightMouseDown, .rightMouseUp)
        case .other: (cgButton, downType, upType) = (.center,.otherMouseDown, .otherMouseUp)
        }
        // Track held state so moveCGCursor can inject drag events while button is down.
        if down { heldButtons.insert(cgButton) } else { heldButtons.remove(cgButton) }
        // Warp cursor to the click position first so the button event injection doesn't
        // carry a cursor position jump — eliminating any synthetic HID move side-effects.
        CGWarpMouseCursorPosition(pt)
        guard let e = CGEvent(mouseEventSource: Self.injectionSource,
                              mouseType: down ? downType : upType,
                              mouseCursorPosition: pt, mouseButton: cgButton) else { return }
        postInjected(e)
    }

    private func injectScroll(at pt: CGPoint, dx: Double, dy: Double) {
        let lines = Int32(dy / 10)
        guard let e = CGEvent(scrollWheelEvent2Source: Self.injectionSource, units: .line,
                              wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        e.location = pt
        postInjected(e)
    }

    private func injectKey(keyCode: UInt16, modifiers: UInt64, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: Self.injectionSource,
                              virtualKey: keyCode, keyDown: down) else { return }
        e.flags = CGEventFlags(rawValue: modifiers)
        postInjected(e)
    }
}

// MARK: - MouseSuppressionTap ─────────────────────────────────────────────────
//
// Intercepts physical mouse events via a CGEventTap installed at cghidEventTap.
// When enabled, physical mouse movement is suppressed (the system cursor doesn't move),
// but injected events tagged with `eventTag` pass through normally.
// Tracks the host's virtual ghost cursor position via raw deltas.

private final class MouseSuppressionTap {

    static let eventTag: Int64 = 0x50454152 // "PEAR"

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var ghostPosition: NSPoint = .zero

    var onGhostMoved: ((NSPoint) -> Void)?
    var onReclaim: (() -> Void)?

    func enable(initialPosition: NSPoint) {
        guard tap == nil else { return }
        ghostPosition = initialPosition

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
            callback: MouseSuppressionTap.tapCallback,
            userInfo: selfPtr
        ) else {
            logger.error("MouseSuppressionTap: failed to create (Accessibility permission required)")
            return
        }

        tap = newTap
        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        // Belt-and-suspenders: CGAssociateMouseAndMouseCursorPosition(false) operates at the
        // display-driver level and prevents the trackpad from advancing the cursor position
        // regardless of the event-tap pipeline. The tap still handles delta accumulation for
        // the ghost and intercepts the reclaim click. CGWarpMouseCursorPosition (used to
        // follow the viewer's cursor) continues to work with association disabled.
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        logger.info("MouseSuppressionTap: enabled")
    }

    func disable() {
        guard tap != nil else { return }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        runLoopSource = nil
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        logger.info("MouseSuppressionTap: disabled")
    }

    deinit { disable() }

    // MARK: - C-compatible callback

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let s = Unmanaged<MouseSuppressionTap>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout {
            if let t = s.tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let tag = event.getIntegerValueField(.eventSourceUserData)

        // Safety net: injected viewer events should be posted at kCGSessionEventTap
        // (downstream of this HID tap) and never arrive here. Pass them through if they do.
        if tag == MouseSuppressionTap.eventTag {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
            let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
            let magnitude = abs(dx) + abs(dy)

            // After CGWarpMouseCursorPosition calls, macOS generates one corrective
            // HID event that includes the full warp displacement as its delta. These
            // warp-correction events have very large magnitudes (50–600px) while real
            // physical trackpad HID events are always <30px per event at 60-120Hz.
            guard magnitude <= 30 else { return nil }

            var pos = s.ghostPosition
            pos.x += dx
            pos.y -= dy
            if let screen = NSScreen.main?.frame {
                pos.x = max(screen.minX, min(screen.maxX, pos.x))
                pos.y = max(screen.minY, min(screen.maxY, pos.y))
            }
            s.ghostPosition = pos
            s.onGhostMoved?(pos)
            return nil

        case .leftMouseDown, .rightMouseDown:
            s.onReclaim?()
            return nil

        case .leftMouseUp, .rightMouseUp:
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
