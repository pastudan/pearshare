import Foundation
import AppKit
import Network
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "ControlChannel")

// MARK: - ControlChannel

/// Manages the bidirectional remote-control data channel on UDP port 5537.
///
/// Viewer side: installs NSEvent global monitors, serialises events as JSON, and
///   sends them over a NWConnection to the host.
///
/// Host side: listens on NWListener, deserialises events, injects them via CGEvent,
///   and repositions the RemoteCursorOverlayWindow to show the remote pointer.
///
/// ScreenHero last-touch model: no locking — both parties can act freely. The host
///   always sees the remote cursor as a teal-ring overlay separate from their own.
@MainActor
final class ControlChannel {

    enum Role { case viewer, host }

    // Callback fired on the main actor when a remote mouse event arrives (host side).
    // Provides the screen-space point so callers can reposition the overlay.
    var onRemoteCursorMoved: ((NSPoint) -> Void)?

    // Callback fired on host when any input event arrives — used to show the
    // "last-touch" badge in the session toolbar.
    var onRemoteActivity: (() -> Void)?

    private let role: Role
    private let port: Int
    private let peerIP: String?         // non-nil on viewer side

    // Viewer side
    private var sendConnection: NWConnection?
    private var eventMonitors: [Any] = []

    // Host side
    private var recvListener: NWListener?

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

    func stop() {
        // Tear down monitors
        for m in eventMonitors { NSEvent.removeMonitor(m) }
        eventMonitors.removeAll()

        sendConnection?.cancel()
        sendConnection = nil
        recvListener?.cancel()
        recvListener = nil
    }

    // MARK: - Viewer: capture events and send

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

        installEventMonitors()
    }

    private func installEventMonitors() {
        // We need BOTH local and global monitors:
        //   - addLocalMonitorForEvents  fires when the event is targeted at our app's windows (window in focus)
        //   - addGlobalMonitorForEvents fires for events delivered to OTHER apps (window not in focus)
        // Together they cover 100% of input regardless of whether the session window is key.

        // Mouse moved — throttled to ≈60 Hz to avoid flooding the control channel.
        var lastMoveSent: TimeInterval = 0
        let moveHandler: (NSEvent) -> Void = { [weak self] event in
            let now = Date().timeIntervalSinceReferenceDate
            guard now - lastMoveSent > 0.016 else { return }
            lastMoveSent = now
            self?.sendMouseMoved(event: event)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: moveHandler) {
            eventMonitors.append(m)
        }
        // Local monitor must return the event (returning nil would swallow it)
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            moveHandler(event); return event
        }) { eventMonitors.append(m) }

        // Helper to register both a global and local monitor for the same mask + handler.
        // Local monitors must return the event; retning nil would swallow it.
        func addBoth(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { eventMonitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in handler(e); return e }) { eventMonitors.append(m) }
        }

        // Left mouse button
        addBoth(.leftMouseDown) { [weak self] event in self?.sendMouseButton(event: event, button: .left,  down: true)  }
        addBoth(.leftMouseUp)   { [weak self] event in self?.sendMouseButton(event: event, button: .left,  down: false) }

        // Right mouse button
        addBoth(.rightMouseDown) { [weak self] event in self?.sendMouseButton(event: event, button: .right, down: true)  }
        addBoth(.rightMouseUp)   { [weak self] event in self?.sendMouseButton(event: event, button: .right, down: false) }

        // Scroll wheel
        addBoth(.scrollWheel) { [weak self] event in self?.sendScroll(event: event) }

        // Key down / up — local monitor returns event so the app still handles it normally
        addBoth(.keyDown) { [weak self] event in self?.sendKey(event: event, down: true)  }
        addBoth(.keyUp)   { [weak self] event in self?.sendKey(event: event, down: false) }
    }

    // MARK: - Coordinate normalisation (viewer → host)

    /// Converts an NSEvent screen point to normalized [0,1] coords on the main display.
    /// NSEvent.mouseLocation is in AppKit screen coords (origin = bottom-left of screen 0).
    private func normalise(screenPoint: NSPoint) -> (x: Double, y: Double) {
        guard let screen = NSScreen.main else { return (0.5, 0.5) }
        let frame = screen.frame
        // Normalize within the screen frame; clamp to [0,1]
        let nx = max(0, min(1, Double((screenPoint.x - frame.origin.x) / frame.width)))
        // AppKit Y is bottom-up; convert to top-down for the wire format
        let ny = max(0, min(1, Double(1.0 - (screenPoint.y - frame.origin.y) / frame.height)))
        return (nx, ny)
    }

    // MARK: - Send helpers

    private func sendMouseMoved(event: NSEvent) {
        let (x, y) = normalise(screenPoint: NSEvent.mouseLocation)
        send(.mouseMoved(x: x, y: y))
    }

    private func sendMouseButton(event: NSEvent, button: ControlEvent.MouseButton, down: Bool) {
        let (x, y) = normalise(screenPoint: NSEvent.mouseLocation)
        send(.mouseButton(x: x, y: y, button: button, down: down))
    }

    private func sendScroll(event: NSEvent) {
        let (x, y) = normalise(screenPoint: NSEvent.mouseLocation)
        send(.scroll(x: x, y: y, dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY)))
    }

    private func sendKey(event: NSEvent, down: Bool) {
        send(.keyEvent(keyCode: event.keyCode,
                       modifiers: UInt64(event.modifierFlags.rawValue),
                       down: down))
    }

    private func send(_ event: ControlEvent) {
        guard let data = event.toData(),
              let conn = sendConnection else { return }
        conn.send(content: data, completion: .idempotent)
    }

    // MARK: - Host: receive events and inject

    private func startHostSide() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(
            using: params,
            on: NWEndpoint.Port(rawValue: UInt16(port))!
        ) else {
            logger.error("ControlChannel host: failed to bind port \(self.port)")
            return
        }

        listener.stateUpdateHandler = { state in
            logger.info("ControlChannel host listener \(String(describing: state))")
        }

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            guard let self else { return }
            self.receiveEvents(from: conn)
        }
        listener.start(queue: .global(qos: .userInteractive))
        self.recvListener = listener
        logger.info("ControlChannel host: listening on port \(self.port)")
    }

    nonisolated private func receiveEvents(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                logger.error("ControlChannel host receive error: \(error)")
                return
            }
            if let data, let event = ControlEvent.from(data: data) {
                Task { @MainActor in
                    self.handleRemoteEvent(event)
                }
            }
            // Loop
            self.receiveEvents(from: connection)
        }
    }

    // MARK: - Event injection (host)

    @MainActor
    private func handleRemoteEvent(_ event: ControlEvent) {
        switch event {
        case .mouseMoved(let nx, let ny):
            let pt = displayPoint(nx: nx, ny: ny)
            moveCGCursor(to: pt)
            // Convert CG screen coords (top-left origin) → AppKit (bottom-left origin)
            let appKitPt = cgPointToAppKit(pt)
            onRemoteCursorMoved?(appKitPt)
            onRemoteActivity?()

        case .mouseButton(let nx, let ny, let button, let down):
            let pt = displayPoint(nx: nx, ny: ny)
            injectMouseButton(at: pt, button: button, down: down)
            onRemoteActivity?()

        case .scroll(let nx, let ny, let dx, let dy):
            let pt = displayPoint(nx: nx, ny: ny)
            injectScroll(at: pt, dx: dx, dy: dy)
            onRemoteActivity?()

        case .keyEvent(let keyCode, let modifiers, let down):
            injectKey(keyCode: keyCode, modifiers: modifiers, down: down)
            onRemoteActivity?()
        }
    }

    // MARK: - Coordinate mapping (host)

    /// Maps normalized [0,1] coords to CGDisplay pixel space (origin = top-left).
    private func displayPoint(nx: Double, ny: Double) -> CGPoint {
        let w = CGFloat(CGDisplayPixelsWide(CGMainDisplayID()))
        let h = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return CGPoint(x: nx * w, y: ny * h)
    }

    /// Converts a CG screen point (origin top-left) to AppKit screen coords (origin bottom-left).
    private func cgPointToAppKit(_ pt: CGPoint) -> NSPoint {
        let h = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        return NSPoint(x: pt.x, y: h - pt.y)
    }

    // MARK: - CGEvent injection

    private func moveCGCursor(to pt: CGPoint) {
        // Move only the on-screen cursor — use a mouseMoved event so Dock/menu bar
        // hover states update, but don't generate a click.
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: pt, mouseButton: .left) else { return }
        e.post(tap: .cghidEventTap)
    }

    private func injectMouseButton(at pt: CGPoint, button: ControlEvent.MouseButton, down: Bool) {
        let cgButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType

        switch button {
        case .left:
            cgButton  = .left
            downType  = .leftMouseDown
            upType    = .leftMouseUp
        case .right:
            cgButton  = .right
            downType  = .rightMouseDown
            upType    = .rightMouseUp
        case .other:
            cgButton  = .center
            downType  = .otherMouseDown
            upType    = .otherMouseUp
        }

        let type = down ? downType : upType
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: pt, mouseButton: cgButton) else { return }
        e.post(tap: .cghidEventTap)
    }

    private func injectScroll(at pt: CGPoint, dx: Double, dy: Double) {
        // CGEventCreateScrollWheelEvent uses integer line deltas; scale the fractional
        // pixel deltas from the viewer to line units (1 line ≈ 10 pixels).
        let lines = Int32(dy / 10)
        guard let e = CGEvent(scrollWheelEvent2Source: nil,
                              units: .line,
                              wheelCount: 1,
                              wheel1: lines,
                              wheel2: 0,
                              wheel3: 0) else { return }
        e.location = pt
        e.post(tap: .cghidEventTap)
    }

    private func injectKey(keyCode: UInt16, modifiers: UInt64, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        e.flags = CGEventFlags(rawValue: modifiers)
        e.post(tap: .cghidEventTap)
    }
}
