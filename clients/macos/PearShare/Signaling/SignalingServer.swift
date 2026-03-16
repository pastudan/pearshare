import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "SignalingServer")

// MARK: - Delegate

@MainActor
protocol SignalingServerDelegate: AnyObject {
    /// Normal incoming ring — show the incoming call UI so the user can accept or decline.
    /// `intent` is "share" (caller sharing) or "request" (caller asking callee to share).
    func signalingServer(_ server: SignalingServer, receivedRingFrom peer: PearPeer, client: SignalingClient, intent: String)

    /// A ring arrived from a trusted device with a valid token — silently start the session.
    func signalingServer(_ server: SignalingServer, autoAcceptedRingFrom peer: PearPeer, descriptor: SessionDescriptor)
}

// MARK: - SignalingServer

/// Listens on TCP port 5534 for incoming ring requests and trust-grant messages from peers.
final class SignalingServer {
    static let port: UInt16 = 5534

    private weak var peerStore: PeerStore?
    private weak var delegate: SignalingServerDelegate?
    private var listener: NWListener?

    init(peerStore: PeerStore, delegate: SignalingServerDelegate) {
        self.peerStore = peerStore
        self.delegate = delegate
    }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(
            using: params,
            on: NWEndpoint.Port(rawValue: Self.port)!
        ) else {
            logger.error("SignalingServer: failed to bind on port \(Self.port)")
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("SignalingServer: listening on port \(Self.port)")
            case .failed(let error):
                logger.error("SignalingServer: listener failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        readMessage(from: connection) { [weak self] data in
            guard let self, let data else { return }
            self.processFirstMessage(data: data, connection: connection)
        }
    }

    private func processFirstMessage(data: Data, connection: NWConnection) {
        guard let envelope = try? JSONDecoder().decode(SignalingEnvelope.self, from: data) else {
            connection.cancel()
            return
        }

        let senderIP = extractIP(from: connection.endpoint) ?? ""

        switch envelope.type {

        case "ring":
            guard let ring = try? JSONDecoder().decode(RingMessage.self, from: data) else {
                connection.cancel()
                return
            }
            handleRing(ring, senderIP: senderIP, connection: connection)

        case "trustGrant":
            guard let grant = try? JSONDecoder().decode(TrustGrantMessage.self, from: data) else {
                connection.cancel()
                return
            }
            handleTrustGrant(grant, senderIP: senderIP)
            connection.cancel()

        default:
            logger.info("SignalingServer: unknown message type '\(envelope.type)', ignoring")
            connection.cancel()
        }
    }

    // MARK: - Ring handling

    private func handleRing(_ ring: RingMessage, senderIP: String, connection: NWConnection) {
        let peer = PearPeer(
            id: senderIP,
            hostName: ring.from,
            displayName: ring.displayName,
            tailscaleIP: senderIP,
            platform: "unknown",
            appVersion: ring.version,
            status: .available,
            lastSeen: Date()
        )
        let client = SignalingClient(existingConnection: connection, peer: peer)

        // Check for a valid trusted token — auto-accept without any UI
        if let token = ring.trustedToken,
           TrustedDeviceStore.shared.isTokenValid(token, for: senderIP) {
            logger.info("SignalingServer: auto-accepting ring from trusted device \(senderIP)")
            // Auto-accept: send accept message immediately, no UI
            client.accept()
            let descriptor = SessionDescriptor(
                sessionId: UUID().uuidString,
                peerIP: senderIP,
                videoPort: 5535,
                audioPort: 5536,
                controlPort: 5537
            )
            Task { @MainActor in
                self.delegate?.signalingServer(self, autoAcceptedRingFrom: peer, descriptor: descriptor)
            }
        } else {
            // Normal ring — show the incoming call UI
            Task { @MainActor in
                self.delegate?.signalingServer(self, receivedRingFrom: peer, client: client, intent: ring.intent)
            }
        }
    }

    // MARK: - Trust grant handling

    private func handleTrustGrant(_ grant: TrustGrantMessage, senderIP: String) {
        // The granter (our peer) is telling us they've trusted us.
        // We store the token under the granter's peer ID so we can include it in future rings.
        let device = TrustedDevice(
            peerID: grant.granterPeerID.isEmpty ? senderIP : grant.granterPeerID,
            displayName: grant.granterDisplayName,
            token: grant.token,
            grantedAt: Date()
        )
        TrustedDeviceStore.shared.grant(device)
        logger.info("SignalingServer: received and stored trust grant from \(grant.granterDisplayName)")
    }

    // MARK: - Helpers

    private func readMessage(from connection: NWConnection, completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            guard error == nil, let data, !data.isEmpty else {
                completion(nil)
                return
            }
            completion(data.trimmingNewline())
        }
    }

    private func extractIP(from endpoint: NWEndpoint) -> String? {
        if case .hostPort(let host, _) = endpoint {
            return "\(host)"
        }
        return nil
    }
}

// MARK: - Data helper

private extension Data {
    func trimmingNewline() -> Data {
        var d = self
        while d.last == 0x0A || d.last == 0x0D { d = d.dropLast() }
        return d
    }
}
