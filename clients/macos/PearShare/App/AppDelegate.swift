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

    // Viewer session: borderless content window
    private var sessionWindow: NSWindow?
    private var rendererCancellable: AnyCancellable?

    private var activeSession: MediaSession?
    private var viewerControlPill: NSWindow?
    private var pillObservers: [Any] = []

    // Multiplayer cursor overlays:
    //   viewerCursorOverlay  — pastel blue, shown on HOST screen when host has control
    //   hostGhostOverlay     — pastel red,  shown on HOST screen when viewer has control
    //   viewerLocalOverlay   — pastel blue, shown on VIEWER screen when viewer is NOT in control
    private var viewerCursorOverlay: RemoteCursorOverlayWindow?
    private var hostGhostOverlay: RemoteCursorOverlayWindow?
    private var viewerLocalOverlay: RemoteCursorOverlayWindow?

    let peerStore = PeerStore()
    private var discovery: PeerDiscovery?
    private var signalingServer: SignalingServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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

    // MARK: - Notification permission (for auto-accept banners)

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "PearShare")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            let p = NSPopover()
            p.contentViewController = NSHostingController(
                rootView: ContactListView(peerStore: peerStore, delegate: self)
            )
            p.contentSize = NSSize(width: 300, height: 400)
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

    // MARK: - Session launch

    func launchSession(descriptor: SessionDescriptor, peer: PearPeer, role: SessionRole) {
        log.info("AppDelegate: launchSession role=\(String(describing: role)) peerIP=\(descriptor.peerIP)")
        activeSession?.stop()

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
        session.overlayWindowTitles = [kViewerCursorWindowTitle, kHostGhostCursorWindowTitle]

        let banner = HostBannerWindow.make(peer: peer) { [weak self] in self?.endSession() }
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
                ctrl.onControlTransfer   = { [weak vco, weak hgo] controller in
                    if controller == .viewer {
                        vco?.hide(); hgo?.show()
                    } else {
                        vco?.show(); hgo?.hide()
                    }
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

        guard let renderer = session.renderer else { return }

        // Borderless window — sized initially to 1280×800, then corrected on first frame.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .black
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()

        let hostingView = NSHostingView(rootView: SessionView(renderer: renderer))
        hostingView.wantsLayer = true
        window.contentView = hostingView
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.setActivationPolicy(.regular)
        self.sessionWindow = window

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
                ctrl.onLocalCursorMoved = { [weak vlo] screenPt in
                    vlo?.moveTo(screenPoint: screenPt)
                    vlo?.show()
                }
                ctrl.onControlTransfer = { [weak vlo] controller in
                    if controller == .viewer { vlo?.hide() } else { vlo?.show() }
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
        log.info("AppDelegate: viewer window sized to \(finalSize.width)×\(finalSize.height) (source \(sourceDimensions.width)×\(sourceDimensions.height) @\(scale)x, 1:1=\(fitsAt1x))")
    }

    // MARK: - End session

    func endSession() {
        guard activeSession != nil || sessionWindow != nil || hostBannerWindow != nil else { return }

        // Capture and nil everything atomically before any teardown to prevent re-entry
        // (e.g. from windowWillClose firing synchronously during sessionWindow?.close()).
        let session     = activeSession
        let window      = sessionWindow
        let banner      = hostBannerWindow
        let cancellable = rendererCancellable

        activeSession       = nil
        sessionWindow       = nil
        hostBannerWindow    = nil
        rendererCancellable = nil

        cancellable?.cancel()

        session?.stop()
        window?.close()
        banner?.close()

        viewerCursorOverlay?.hide(); viewerCursorOverlay = nil
        hostGhostOverlay?.hide();    hostGhostOverlay    = nil
        viewerLocalOverlay?.hide();  viewerLocalOverlay  = nil

        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Auto-accept notification banner

    private func showAutoAcceptNotification(for peer: PearPeer) {
        let content = UNMutableNotificationContent()
        content.title = "Remote session started"
        content.body = "\(peer.displayName) connected to your screen via trusted access."
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
        guard activeSession == nil else { return }

        requestAccessibilityIfNeeded()

        Task {
            guard await ScreenCapturePermission.requestIfNeeded() else { return }

            let client = SignalingClient(peer: peer, peerStore: peerStore)
            client.onAccepted = { [weak self] descriptor in
                log.info("AppDelegate: ring accepted, launching host session to \(descriptor.peerIP):\(descriptor.videoPort)")
                self?.launchSession(descriptor: descriptor, peer: peer, role: .host)
            }
            client.ring()
        }
    }

    func requestScreen(from peer: PearPeer) {
        guard activeSession == nil else { return }

        Task {
            let client = SignalingClient(peer: peer, peerStore: peerStore)
            client.onAccepted = { [weak self] descriptor in
                log.info("AppDelegate: screen request accepted, launching viewer session")
                self?.launchSession(descriptor: descriptor, peer: peer, role: .viewer)
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
}

// MARK: - SignalingServerDelegate

extension AppDelegate: SignalingServerDelegate {
    func signalingServer(_ server: SignalingServer, receivedRingFrom peer: PearPeer, client: SignalingClient, intent: String) {
        DispatchQueue.main.async { [weak self] in
            self?.showIncomingRing(from: peer, client: client, intent: intent)
        }
    }

    func signalingServer(_ server: SignalingServer, autoAcceptedRingFrom peer: PearPeer, descriptor: SessionDescriptor, intent: String) {
        log.info("AppDelegate: auto-accepted ring from trusted device \(peer.tailscaleIP) intent=\(intent)")
        showAutoAcceptNotification(for: peer)
        let role: SessionRole = intent == "request" ? .host : .viewer
        launchSession(descriptor: descriptor, peer: peer, role: role)
    }
}
