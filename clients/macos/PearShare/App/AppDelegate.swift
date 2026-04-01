import AppKit
import ApplicationServices
import SwiftUI
import Combine
import UserNotifications
import OSLog

private let log = Logger(subsystem: "com.pearshare.app", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var ringerWindow: NSWindow?

    // Host session: small draggable banner (no full window)
    private var hostBannerWindow: NSWindow?

    // Viewer session: borderless content window + floating control pill
    private var sessionWindow: NSWindow?
    private var viewerControlPill: ViewerControlPillPanel?
    private var pillObservers: [NSObjectProtocol] = []
    private var rendererCancellable: AnyCancellable?

    private var activeSession: MediaSession?
    private var sessionCounter = 0  // incremented each time launchSession is called

    // Outgoing call state (while we're ringing a peer and waiting for them to answer)
    private var outgoingCallWindow: NSWindow?
    private var activeSignalingClient: SignalingClient?

    // Deferred activation-policy restore: set when endSession() needs to switch back to
    // .accessory but the menu-bar popover is open (switching while it's shown dismisses it).
    // Applied in popoverDidClose(_:) instead.
    private var pendingActivationPolicyRestore = false

    // Host screen-share border (optional visual indicator)
    private var screenShareBorderWindow: ScreenShareBorderWindow?

    // Multiplayer cursor overlays:
    //   viewerCursorOverlay  — pastel blue, shown on HOST screen when host has control
    //   hostGhostOverlay     — pastel red,  shown on HOST screen when viewer has control
    //   viewerLocalOverlay   — pastel blue, shown on VIEWER screen when viewer is NOT in control
    //   viewerHostOverlay    — pastel red,  shown on VIEWER screen when viewer has control
    private var viewerCursorOverlay: RemoteCursorOverlayWindow?
    private var hostGhostOverlay: RemoteCursorOverlayWindow?
    private var viewerLocalOverlay: RemoteCursorOverlayWindow?
    private var viewerHostOverlay: RemoteCursorOverlayWindow?

    // Viewer-side control state
    private var viewerIsInControl = false
    private var isViewerCursorHidden = false
    // NSEvent monitors used on the viewer side (stored as Any; cleaned up in endSession)
    private var viewerEventMonitors: [Any] = []

    let peerStore = PeerStore()
    let sessionStateStore = SessionStateStore()
    private var discovery: PeerDiscovery?
    private var signalingServer: SignalingServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [PearSettings.showScreenShareBorderKey: true])
        NSApp.setActivationPolicy(.accessory)
        // Ensure cursor-mouse association is enabled at launch (recovery from a previous crash
        // that may have left CGAssociateMouseAndMouseCursorPosition(false) in effect).
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        setupStatusItem()
        startServices()
        Task { await ScreenCapturePermission.requestIfNeeded() }
        requestNotificationPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        discovery?.stop()
        signalingServer?.stop()
        activeSession?.stop()
    }

    // MARK: - Accessibility permission (needed for CGEvent injection on host)

    @discardableResult
    func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Viewer cursor visibility helpers

    /// Hide the viewer's system cursor (used when host has control).
    /// Balanced with showViewerCursor(); safe to call redundantly.
    private func hideViewerCursor() {
        guard !isViewerCursorHidden else { return }
        isViewerCursorHidden = true
        NSCursor.hide()
    }

    /// Restore the viewer's system cursor. Safe to call redundantly.
    private func showViewerCursor() {
        guard isViewerCursorHidden else { return }
        isViewerCursorHidden = false
        NSCursor.unhide()
    }

    // MARK: - Notification permission (for auto-accept banners)

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateMenuBarIcon(inSession: false)
    }

    private func updateMenuBarIcon(inSession: Bool) {
        guard let button = statusItem?.button else { return }
        if inSession {
            let config = NSImage.SymbolConfiguration(paletteColors: [.pearGreen])
            if let img = NSImage(systemSymbolName: "person.2.fill",
                                 accessibilityDescription: "PearShare active")?
                            .withSymbolConfiguration(config) {
                img.isTemplate = false
                button.image = img
            }
        } else {
            let img = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "PearShare")
            img?.isTemplate = true
            button.image = img
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            let p = NSPopover()
            p.delegate = self
            p.contentViewController = NSHostingController(
                rootView: ContactListView(peerStore: peerStore, sessionState: sessionStateStore, delegate: self)
            )
            p.contentSize = NSSize(width: 300, height: 420)
            p.behavior = .transient
            p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover = p
        }
    }

    // MARK: - Services

    private func startServices() {
        let tailscale = TailscaleClient()
        discovery = PeerDiscovery(tailscaleClient: tailscale, peerStore: peerStore)
        discovery?.start()

        signalingServer = SignalingServer(peerStore: peerStore, delegate: self)
        signalingServer?.start()
    }

    // MARK: - Incoming ring UI

    func showIncomingRing(from peer: PearPeer, client: SignalingClient, intent: String) {
        let acceptRole: SessionRole = intent == "request" ? .host : .viewer

        let width: CGFloat = intent == "request" ? 400 : 360
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.center()

        let view = IncomingRingView(peer: peer, intent: intent) { [weak self] accepted in
            self?.ringerWindow?.orderOut(nil)
            self?.ringerWindow = nil
            if accepted {
                log.info("AppDelegate: user accepted ring from \(peer.tailscaleIP), intent=\(intent), launching \(String(describing: acceptRole)) session")
                client.accept()
                self?.launchSession(descriptor: SessionDescriptor(
                    sessionId: UUID().uuidString,
                    peerIP: peer.tailscaleIP,
                    videoPort: 5535,
                    audioPort: 5536,
                    controlPort: 5537
                ), peer: peer, role: acceptRole)
            } else {
                client.reject(reason: "declined")
            }
        }
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        self.ringerWindow = window
    }

    // MARK: - Outgoing call UI

    private func showOutgoingCall(peer: PearPeer, intent: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.center()

        let view = OutgoingCallView(peer: peer, intent: intent) { [weak self] in
            self?.activeSignalingClient?.cancel()
            self?.activeSignalingClient = nil
            self?.dismissOutgoingCallWindow()
        }
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        self.outgoingCallWindow = window
    }

    private func dismissOutgoingCallWindow() {
        outgoingCallWindow?.orderOut(nil)
        outgoingCallWindow = nil
    }

    // MARK: - Session launch

    func launchSession(descriptor: SessionDescriptor, peer: PearPeer, role: SessionRole) {
        sessionCounter += 1
        let sn = sessionCounter
        tapLog("[SESSION-\(sn)] launchSession role=\(role) peerIP=\(descriptor.peerIP) controlPort=\(descriptor.controlPort)")
        log.info("AppDelegate: launchSession #\(sn) role=\(String(describing: role)) peerIP=\(descriptor.peerIP)")
        activeSession?.stop()
        sessionStateStore.activePeer = peer
        sessionStateStore.role = role
        updateMenuBarIcon(inSession: true)

        let session = MediaSession(descriptor: descriptor, role: role)
        activeSession = session

        session.onStop = { [weak self] in
            DispatchQueue.main.async { self?.endSession() }
        }

        switch role {
        case .host:
            launchHostSession(session: session, peer: peer)
        case .viewer:
            launchViewerSession(session: session, peer: peer, descriptor: descriptor)
        }
    }

    // MARK: - Host session (floating banner, no full window)

    private func launchHostSession(session: MediaSession, peer: PearPeer) {
        // Pre-create overlays so their titles are available for SCContentFilter exclusion.
        let vco = RemoteCursorOverlayWindow.pastelBlue(peerName: peer.displayName)
        let hgo = RemoteCursorOverlayWindow.pastelRed(peerName: "Me")
        self.viewerCursorOverlay = vco
        self.hostGhostOverlay = hgo
        let showBorder = UserDefaults.standard.bool(forKey: PearSettings.showScreenShareBorderKey)
        let borderTitles: [String] = showBorder ? [kScreenShareBorderWindowTitle] : []
        session.overlayWindowTitles = [kViewerCursorWindowTitle, kHostGhostCursorWindowTitle, kHostBannerWindowTitle] + borderTitles

        session.debugInfo.roleLabel     = "Host"
        session.debugInfo.peerIP        = peer.tailscaleIP
        session.debugInfo.peerHostname  = peer.displayName

        // Show border first so the banner (ordered front after) appears in front of it.
        if showBorder, let screen = NSScreen.main ?? NSScreen.screens.first {
            let border = ScreenShareBorderWindow.make(screen: screen)
            border.orderFrontRegardless()
            self.screenShareBorderWindow = border
            tapLog("[HOST-BORDER] border shown: frame=\(Int(screen.frame.width))×\(Int(screen.frame.height)) origin=(\(Int(screen.frame.minX)),\(Int(screen.frame.minY)))")
        } else {
            tapLog("[HOST-BORDER] border skipped: showBorder=\(showBorder) hasScreen=\(NSScreen.main != nil)")
        }

        let banner = HostBannerWindow.make(
            peer: peer,
            debugInfo: session.debugInfo,
            onHangup: { [weak self] in self?.endSession() },
            onInputToggled: { [weak self] enabled in
                self?.activeSession?.controlChannel?.setInputEnabled(enabled)
            }
        )
        banner.orderFrontRegardless()
        self.hostBannerWindow = banner

        Task {
            do {
                try await session.start()
                guard let ctrl = session.controlChannel else { return }

                vco.show()
                hgo.hide()

                ctrl.onRemoteCursorMoved = { [weak vco] screenPt in vco?.moveTo(screenPoint: screenPt) }
                ctrl.onHostCursorMoved   = { [weak hgo] screenPt in hgo?.moveTo(screenPoint: screenPt) }
                ctrl.onControlTransfer   = { [weak self, weak vco, weak hgo] controller in
                    if controller == .viewer {
                        // Viewer has control: hide system cursor from stream, show host ghost D
                        vco?.hide(); hgo?.show()
                        self?.activeSession?.setShowsCursor(false)
                    } else {
                        // Host has control: show system cursor in stream, show viewer cursor overlay
                        vco?.show(); hgo?.hide()
                        self?.activeSession?.setShowsCursor(true)
                    }
                }
                let sn = self.sessionCounter
                tapLog("[SESSION-\(sn)] host ctrl.onHangup wired")
                ctrl.onHangup = { [weak self] in
                    tapLog("[SESSION-\(sn)] host onHangup fired → endSession")
                    self?.endSession()
                }
            } catch {
                log.error("AppDelegate: host session.start() threw: \(error)")
                endSession()
                showAlert(title: "Session failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Viewer session (borderless window + floating control pill)

    private func launchViewerSession(session: MediaSession, peer: PearPeer, descriptor: SessionDescriptor) {
        let vlo = RemoteCursorOverlayWindow.pastelBlue(peerName: "Me")
        self.viewerLocalOverlay = vlo
        let vho = RemoteCursorOverlayWindow.pastelRed(peerName: peer.displayName)
        self.viewerHostOverlay = vho

        guard let renderer = session.renderer else { return }

        // Borderless window — sized initially to 1280×800, then corrected on first frame.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false  // drag must not move window; all drags go to host
        window.delegate = self
        window.center()

        let hostingView = NSHostingView(rootView: SessionView(renderer: renderer))
        hostingView.wantsLayer = true
        hostingView.autoresizingMask = [.width, .height]

        // ViewerWindowContentView is the actual contentView — it provides resize cursor
        // rects that a .borderless window would otherwise never show.
        let contentWrapper = ViewerWindowContentView()
        contentWrapper.addSubview(hostingView)
        window.contentView = contentWrapper
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.setActivationPolicy(.regular)
        self.sessionWindow = window

        session.debugInfo.roleLabel     = "Viewer"
        session.debugInfo.peerIP        = peer.tailscaleIP
        session.debugInfo.peerHostname  = peer.displayName

        // Control pill — child of the session window so the compositor always keeps it above.
        // Moves are handled automatically (child follows parent); only resize needs manual
        // repositioning to keep the pill anchored to the new top edge.
        let pill = ViewerControlPillPanel.make(debugInfo: session.debugInfo) { [weak self] in self?.endSession() }
        self.viewerControlPill = pill
        repositionControlPill()
        window.addChildWindow(pill, ordered: .above)

        let resizeObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.repositionControlPill() } }
        pillObservers = [resizeObs]

        // Real-time pill drag: NSWindow.didMoveNotification is only posted AFTER a drag ends
        // when isMovableByWindowBackground is used, so we track it manually with local event
        // monitors instead. These fire continuously during the drag.
        installPillDragMonitors(pill: pill)

        // Observe source dimensions: size window to 1:1 or scale-to-fit on first frame.
        rendererCancellable = renderer.$sourceDimensions
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak window] dims in
                guard let self, let window else { return }
                self.applySmartWindowSize(sourceDimensions: dims, window: window)
            }

        Task {
            do {
                try await session.start()
                guard let ctrl = session.controlChannel else { return }

                ctrl.sessionWindowFrameProvider = { [weak window] in
                    window?.contentView?.window?.convertToScreen(
                        window?.contentView?.bounds ?? .zero
                    )
                }

                // C — blue "Me" overlay: visible only when host has control.
                // D (on viewer) — red host overlay: visible only when viewer has control.
                // System cursor: hidden when host has control, shown when viewer has control.
                ctrl.onControlTransfer = { [weak self, weak vlo, weak vho] controller in
                    guard let self else { return }
                    let inControl = (controller == .viewer)
                    self.viewerIsInControl = inControl
                    if inControl {
                        // Viewer took control: show system cursor A + red host ghost D; hide C.
                        vlo?.hide()
                        self.showViewerCursor()
                        vho?.show()
                    } else {
                        // Host took control: hide system cursor; show C; hide D.
                        vho?.hide()
                        self.hideViewerCursor()
                        vlo?.moveTo(screenPoint: NSEvent.mouseLocation)
                        vlo?.show()
                    }
                }
                ctrl.onLocalCursorMoved = { [weak self, weak vlo] screenPt in
                    vlo?.moveTo(screenPoint: screenPt)
                    // Only show C when host has control (viewer has control → system cursor A is shown).
                    if self?.viewerIsInControl == false { vlo?.show() }
                }
                ctrl.onRemoteHostCursorMoved = { [weak vho] screenPt in
                    vho?.moveTo(screenPoint: screenPt)
                }
                ctrl.onMouseExitedWindow = { [weak self, weak vlo, weak vho] in
                    vlo?.hide()
                    vho?.hide()
                    self?.showViewerCursor()
                }
                let sn = self.sessionCounter
                tapLog("[SESSION-\(sn)] viewer ctrl.onHangup wired")
                ctrl.onHangup = { [weak self] in
                    tapLog("[SESSION-\(sn)] viewer onHangup fired → endSession")
                    self?.endSession()
                }
            } catch {
                log.error("AppDelegate: viewer session.start() threw: \(error)")
                endSession()
                showAlert(title: "Session failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Smart window sizing (1:1 pixels if host fits on viewer screen, else scale-to-fit)

    private func applySmartWindowSize(sourceDimensions: CGSize, window: NSWindow) {
        let scale = window.backingScaleFactor
        let sourcePoints = CGSize(
            width:  sourceDimensions.width  / scale,
            height: sourceDimensions.height / scale
        )
        let available = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let fitsAt1x = sourcePoints.width  <= available.width
                    && sourcePoints.height <= available.height

        let finalSize: CGSize
        if fitsAt1x {
            finalSize = sourcePoints
        } else {
            let factor = min(available.width  / sourcePoints.width,
                            available.height / sourcePoints.height)
            finalSize = CGSize(width:  sourcePoints.width  * factor,
                               height: sourcePoints.height * factor)
        }

        window.setFrame(
            NSRect(x: window.frame.origin.x, y: window.frame.origin.y,
                   width: finalSize.width,    height: finalSize.height),
            display: true, animate: false
        )
        window.center()
        window.contentAspectRatio = finalSize
        repositionControlPill()
        log.info("AppDelegate: viewer window sized to \(finalSize.width)×\(finalSize.height) (source \(sourceDimensions.width)×\(sourceDimensions.height) @\(scale)x, 1:1=\(fitsAt1x))")
        tapLog("[VIEWER-4] Window sizing: source=\(Int(sourceDimensions.width))×\(Int(sourceDimensions.height)) px  |  backingScale=\(scale)x  |  sourceInPts=\(Int(sourcePoints.width))×\(Int(sourcePoints.height))  |  screenAvail=\(Int(available.width))×\(Int(available.height)) pts  |  fits1:1=\(fitsAt1x)  |  finalWindow=\(Int(finalSize.width))×\(Int(finalSize.height)) pts")
    }

    // MARK: - Control pill positioning

    private func repositionControlPill() {
        guard let window = sessionWindow, let pill = viewerControlPill else { return }
        // Center horizontally; straddle the top edge (20 pt above, 20 pt below).
        let x = window.frame.midX - pill.frame.width / 2
        let y = window.frame.maxY - pill.frame.height / 2
        pill.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Inverse of repositionControlPill: move the session window to stay anchored below the pill.
    /// Install local NSEvent monitors that move the pill (and session window) in real-time
    /// while the user drags the pill. Local monitors fire continuously during the drag,
    /// unlike NSWindow.didMoveNotification which only fires after the drag completes.
    private func installPillDragMonitors(pill: NSWindow) {
        var dragActive = false
        var anchorMouse = NSPoint.zero
        var anchorWindowOrigin = NSPoint.zero   // anchor the SESSION WINDOW, not the pill

        // Dragging the pill moves the session window; the pill follows automatically as a child.
        // Anchoring the parent avoids the double-move that would occur if we moved the child
        // and then also moved the parent to follow it.
        let downM = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak pill] event in
            if let pill, pill.frame.contains(NSEvent.mouseLocation) {
                dragActive = true
                anchorMouse = NSEvent.mouseLocation
                anchorWindowOrigin = self?.sessionWindow?.frame.origin ?? .zero
                self?.sessionWindow?.orderFront(nil)
            }
            return event
        }
        let dragM = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard dragActive, let window = self?.sessionWindow else { return event }
            let cur = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(
                x: anchorWindowOrigin.x + cur.x - anchorMouse.x,
                y: anchorWindowOrigin.y + cur.y - anchorMouse.y
            ))
            return event
        }
        let upM = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            dragActive = false; return event
        }
        viewerEventMonitors += [downM, dragM, upM].compactMap { $0 }
    }

    // MARK: - End session

    func endSession() {
        let sn = sessionCounter
        tapLog("[SESSION-\(sn)] endSession called — activeSession=\(activeSession != nil) window=\(sessionWindow != nil) banner=\(hostBannerWindow != nil)")
        guard activeSession != nil || sessionWindow != nil || hostBannerWindow != nil else {
            tapLog("[SESSION-\(sn)] endSession: guard failed (already torn down), returning")
            return
        }

        // Capture and nil everything atomically before any teardown to prevent re-entry
        // (e.g. from windowWillClose firing synchronously during sessionWindow?.close()).
        let session     = activeSession
        let window      = sessionWindow
        let banner      = hostBannerWindow
        let pill        = viewerControlPill
        let observers   = pillObservers
        let cancellable = rendererCancellable

        activeSession       = nil
        sessionWindow       = nil
        hostBannerWindow    = nil
        viewerControlPill   = nil
        pillObservers       = []
        rendererCancellable = nil

        cancellable?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        viewerEventMonitors.forEach { NSEvent.removeMonitor($0) }
        viewerEventMonitors = []

        // Notify the peer before tearing down the control channel.
        let ctrl = session?.controlChannel
        tapLog("[SESSION-\(sn)] endSession: ctrl=\(ctrl != nil)  calling sendHangup")
        ctrl?.sendHangup()
        session?.stop()

        // Dissolve the child-window relationship before ordering out. If we skip this,
        // ordering out the parent also hides the child, but the explicit removeChildWindow
        // ensures AppKit doesn't try to re-show the child when the parent is later released.
        if let pill { window?.removeChildWindow(pill) }

        // Use orderOut rather than close so AppKit doesn't snapshot the Metal view
        // (now invalidated) for a window-close animation — which would crash in
        // _NSWindowTransformAnimation dealloc when it tries to release freed textures.
        window?.orderOut(nil)
        pill?.orderOut(nil)
        banner?.orderOut(nil)

        viewerCursorOverlay?.hide(); viewerCursorOverlay = nil
        hostGhostOverlay?.hide();    hostGhostOverlay    = nil
        viewerLocalOverlay?.hide();  viewerLocalOverlay  = nil
        viewerHostOverlay?.hide();   viewerHostOverlay   = nil
        screenShareBorderWindow?.orderOut(nil); screenShareBorderWindow = nil

        showViewerCursor()
        viewerIsInControl = false

        sessionStateStore.activePeer = nil
        sessionStateStore.role = nil
        updateMenuBarIcon(inSession: false)

        // Only switch back to .accessory when we actually promoted to .regular —
        // which only happens for viewer sessions (the session window was present).
        // If the menu-bar popover is currently open, defer the switch: calling
        // setActivationPolicy while the popover is visible dismisses it immediately.
        // popoverDidClose(_:) picks up the deferred flag and applies it then.
        if window != nil {
            if popover?.isShown == true {
                pendingActivationPolicyRestore = true
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: - Auto-accept notification banner

    private func showAutoAcceptNotification(for peer: PearPeer, intent: String) {
        let content = UNMutableNotificationContent()
        if intent == "share" {
            content.title = "Screen share started"
            content.body = "\(peer.displayName) is now sharing their screen with you."
        } else {
            content.title = "Remote session started"
            content.body = "\(peer.displayName) connected to your screen via trusted access."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "autoaccept-\(peer.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log.error("AppDelegate: notification error: \(error)") }
        }
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - ContactListViewDelegate

extension AppDelegate: ContactListViewDelegate {
    func ring(peer: PearPeer) {
        guard activeSession == nil, outgoingCallWindow == nil else { return }

        requestAccessibilityIfNeeded()

        Task {
            guard await ScreenCapturePermission.requestIfNeeded() else { return }

            let client = SignalingClient(peer: peer, peerStore: peerStore)
            activeSignalingClient = client
            client.onRinging = { [weak self] in
                self?.showOutgoingCall(peer: peer, intent: "share")
            }
            client.onAccepted = { [weak self] descriptor in
                self?.activeSignalingClient = nil
                self?.dismissOutgoingCallWindow()
                log.info("AppDelegate: ring accepted, launching host session to \(descriptor.peerIP):\(descriptor.videoPort)")
                self?.launchSession(descriptor: descriptor, peer: peer, role: .host)
            }
            client.onFailed = { [weak self] _ in
                self?.activeSignalingClient = nil
                self?.dismissOutgoingCallWindow()
            }
            client.ring()
        }
    }

    func requestScreen(from peer: PearPeer) {
        guard activeSession == nil, outgoingCallWindow == nil else { return }

        Task {
            let client = SignalingClient(peer: peer, peerStore: peerStore)
            activeSignalingClient = client
            client.onRinging = { [weak self] in
                self?.showOutgoingCall(peer: peer, intent: "request")
            }
            client.onAccepted = { [weak self] descriptor in
                self?.activeSignalingClient = nil
                self?.dismissOutgoingCallWindow()
                log.info("AppDelegate: screen request accepted, launching viewer session")
                self?.launchSession(descriptor: descriptor, peer: peer, role: .viewer)
            }
            client.onFailed = { [weak self] _ in
                self?.activeSignalingClient = nil
                self?.dismissOutgoingCallWindow()
            }
            client.ringAsRequest()
        }
    }

    func grantTrust(to peer: PearPeer) {
        guard let pubKey = peer.publicKey, !pubKey.isEmpty else {
            showAlert(title: "Can't add trusted device", message: "This peer didn't advertise a public key. They may need to update PearShare.")
            return
        }
        let device = TrustedDevice(
            peerID: peer.id,
            displayName: peer.displayName,
            publicKey: pubKey,
            grantedAt: Date()
        )
        TrustedDeviceStore.shared.grant(device)
        log.info("AppDelegate: granted auto-answer to \(peer.displayName) (\(peer.id))")
    }
}

// MARK: - NSWindowDelegate (viewer window close → hang up)

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === sessionWindow else { return }
        endSession()
    }

    /// Viewer left the session window (alt-tab, etc.) — hide overlay and restore cursor
    /// so PearShare's hidden cursor state doesn't bleed into other apps.
    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === sessionWindow else { return }
        viewerLocalOverlay?.hide()
        viewerHostOverlay?.hide()
        showViewerCursor()
    }

    /// Viewer came back to the session window — re-apply cursor state based on who's in control.
    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === sessionWindow else { return }
        if viewerIsInControl {
            // Viewer has control: restore system cursor + red host ghost
            viewerHostOverlay?.show()
        } else {
            // Host has control: hide system cursor, show blue local overlay
            hideViewerCursor()
            viewerLocalOverlay?.moveTo(screenPoint: NSEvent.mouseLocation)
            viewerLocalOverlay?.show()
        }
    }
}

// MARK: - SignalingServerDelegate

extension AppDelegate: SignalingServerDelegate {
    func signalingServer(_ server: SignalingServer, receivedRingFrom peer: PearPeer, client: SignalingClient, intent: String) {
        DispatchQueue.main.async { [weak self] in
            self?.showIncomingRing(from: peer, client: client, intent: intent)
        }
    }

    func signalingServer(_ server: SignalingServer, autoAcceptedRingFrom peer: PearPeer, descriptor: SessionDescriptor, intent: String) {
        log.info("AppDelegate: auto-accepted ring from \(peer.tailscaleIP) intent=\(intent)")
        showAutoAcceptNotification(for: peer, intent: intent)
        let role: SessionRole = intent == "request" ? .host : .viewer
        launchSession(descriptor: descriptor, peer: peer, role: role)
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if pendingActivationPolicyRestore {
            pendingActivationPolicyRestore = false
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
