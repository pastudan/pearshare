import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications
import OSLog

private let log = Logger(subsystem: "com.pearshare.app", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var ringerWindow: NSWindow?
    private var sessionWindow: NSWindow?
    private var cursorOverlayWindow: RemoteCursorOverlayWindow?
    private var activeSession: MediaSession?

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
        // For a "request": caller wants us to share our screen → we become host on accept.
        // For a "share": caller is sharing their screen → we become viewer on accept.
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

    // MARK: - Session window

    func launchSession(descriptor: SessionDescriptor, peer: PearPeer, role: SessionRole) {
        log.info("AppDelegate: launchSession role=\(String(describing: role)) peerIP=\(descriptor.peerIP) videoPort=\(descriptor.videoPort)")
        activeSession?.stop()

        let session = MediaSession(descriptor: descriptor, role: role)
        activeSession = session

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PearShare — \(peer.displayName)"
        window.center()

        let remoteControlState = RemoteControlState()
        let sessionView = SessionView(
            session: session,
            peer: peer,
            remoteControlState: remoteControlState
        ) { [weak self] in
            self?.endSession()
        }
        window.contentView = NSHostingView(rootView: sessionView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.sessionWindow = window

        session.onStop = { [weak self] in
            DispatchQueue.main.async {
                self?.sessionWindow?.orderOut(nil)
                self?.sessionWindow = nil
                self?.activeSession = nil
                self?.cursorOverlayWindow?.hide()
                self?.cursorOverlayWindow = nil
            }
        }

        if role == .host {
            let overlay = RemoteCursorOverlayWindow()
            overlay.peerDisplayName = peer.displayName
            self.cursorOverlayWindow = overlay
            session.overlayWindowTitle = kRemoteCursorWindowTitle
        }

        Task {
            do {
                log.info("AppDelegate: calling session.start() for role=\(String(describing: role))")
                try await session.start()
                log.info("AppDelegate: session.start() returned successfully")

                if role == .host, let ctrl = session.controlChannel {
                    let overlay = self.cursorOverlayWindow
                    ctrl.onRemoteCursorMoved = { [weak overlay] screenPt in
                        overlay?.moveTo(screenPoint: screenPt)
                        overlay?.show()
                    }
                    ctrl.onRemoteActivity = { [weak remoteControlState] in
                        remoteControlState?.markActive()
                    }
                }
            } catch {
                log.error("AppDelegate: session.start() threw: \(error)")
                endSession()
                showAlert(title: "Session failed", message: error.localizedDescription)
            }
        }
    }

    func endSession() {
        activeSession?.stop()
        sessionWindow?.orderOut(nil)
        sessionWindow = nil
        activeSession = nil
        cursorOverlayWindow?.hide()
        cursorOverlayWindow = nil
    }

    // MARK: - Auto-accept notification banner

    /// Shows a transient system notification so the host is always aware a remote
    /// session started silently via trusted-device auto-accept.
    private func showAutoAcceptNotification(for peer: PearPeer) {
        let content = UNMutableNotificationContent()
        content.title = "Remote session started"
        content.body = "\(peer.displayName) connected to your screen via trusted access."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "autoaccept-\(peer.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
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

    /// Caller asks the peer to share their screen — caller watches (viewer), peer shares (host).
    func requestScreen(from peer: PearPeer) {
        guard activeSession == nil else { return }

        Task {
            let client = SignalingClient(peer: peer, peerStore: peerStore)
            client.onAccepted = { [weak self] descriptor in
                log.info("AppDelegate: screen request accepted, launching viewer session")
                // We requested their screen — we are the viewer
                self?.launchSession(descriptor: descriptor, peer: peer, role: .viewer)
            }
            client.ringAsRequest()
        }
    }

    /// Called after the user passes both TrustApprovalView stages.
    /// Generates a token, stores it locally (so we can validate incoming rings),
    /// and sends a TrustGrantMessage to the peer (so they can include it in future rings).
    func grantTrust(to peer: PearPeer) {
        let token = TrustedDeviceStore.generateToken()

        // Store on our side — we are the granter; we validate this token on incoming rings
        let device = TrustedDevice(
            peerID: peer.id,
            displayName: peer.displayName,
            token: token,
            grantedAt: Date()
        )
        TrustedDeviceStore.shared.grant(device)
        log.info("AppDelegate: granted trust to \(peer.displayName), sending TrustGrant")

        // Send the token to the peer so they can include it in future rings
        let myName = Host.current().localizedName ?? "PearShare"
        // Our own Tailscale IP is needed as the key on the peer side.
        // PeerDiscovery stores it in peerStore.selfIP; fall back to an empty string if unavailable.
        let myIP = peerStore.selfIP ?? ""
        let client = SignalingClient(peer: peer, peerStore: peerStore)
        client.sendTrustGrant(token: token, myDisplayName: myName, myPeerID: myIP)
    }
}

// MARK: - SignalingServerDelegate

extension AppDelegate: SignalingServerDelegate {
    func signalingServer(_ server: SignalingServer, receivedRingFrom peer: PearPeer, client: SignalingClient, intent: String) {
        DispatchQueue.main.async { [weak self] in
            self?.showIncomingRing(from: peer, client: client, intent: intent)
        }
    }

    /// Trusted-device ring: silently start sharing screen, show notification banner only.
    func signalingServer(_ server: SignalingServer, autoAcceptedRingFrom peer: PearPeer, descriptor: SessionDescriptor) {
        log.info("AppDelegate: auto-accepted ring from trusted device \(peer.tailscaleIP)")
        showAutoAcceptNotification(for: peer)
        // Auto-accept: this machine becomes the viewer (watches the caller's screen, which is what they want)
        launchSession(descriptor: descriptor, peer: peer, role: .viewer)
    }
}
