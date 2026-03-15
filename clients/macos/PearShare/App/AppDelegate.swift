import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var ringerWindow: NSWindow?
    private var sessionWindow: NSWindow?
    private var activeSession: MediaSession?

    let peerStore = PeerStore()
    private var discovery: PeerDiscovery?
    private var signalingServer: SignalingServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        startServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        discovery?.stop()
        signalingServer?.stop()
        activeSession?.stop()
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

    func showIncomingRing(from peer: PearPeer, client: SignalingClient) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.center()

        let view = IncomingRingView(peer: peer) { [weak self] accepted in
            self?.ringerWindow?.orderOut(nil)
            self?.ringerWindow = nil
            if accepted {
                client.accept()
                // Host: they're sharing their screen to us — we're the viewer
                self?.launchSession(descriptor: SessionDescriptor(
                    sessionId: UUID().uuidString,
                    peerIP: peer.tailscaleIP,
                    videoPort: 5535,
                    audioPort: 5536,
                    controlPort: 5537
                ), peer: peer, role: .viewer)
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

        let sessionView = SessionView(session: session, peer: peer) { [weak self] in
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
            }
        }

        Task {
            do {
                try await session.start()
            } catch {
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
        guard activeSession == nil else { return } // already in a session

        let client = SignalingClient(peer: peer, peerStore: peerStore)
        client.onAccepted = { [weak self] descriptor in
            // We rang them, they accepted — we're the host (sharing our screen)
            self?.launchSession(descriptor: descriptor, peer: peer, role: .host)
        }
        client.ring()
    }
}

// MARK: - SignalingServerDelegate

extension AppDelegate: SignalingServerDelegate {
    func signalingServer(_ server: SignalingServer, receivedRingFrom peer: PearPeer, client: SignalingClient) {
        DispatchQueue.main.async { [weak self] in
            self?.showIncomingRing(from: peer, client: client)
        }
    }
}
