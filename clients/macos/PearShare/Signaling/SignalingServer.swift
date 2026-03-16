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

    /// A ring arrived from a caller we trust (signature over nonce verified) — silently start the session.
    func signalingServer(_ server: SignalingServer, autoAcceptedRingFrom peer: PearPeer, descriptor: SessionDescriptor, intent: String)
}

// MARK: - SignalingServer

/// Listens on TCP port 5534 for incoming ring requests from peers.
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
            lastSeen: Date(),
            publicKey: nil
        )
        let client = SignalingClient(existingConnection: connection, peer: peer)

        // Pubkey-based auto-answer: we have caller's pubkey in our trusted list and they proved identity
        if let nonceB64 = ring.nonce,
           let sigB64 = ring.signature,
           let nonce = Data(base64Encoded: nonceB64),
           let signature = Data(base64Encoded: sigB64),
           TrustedDeviceStore.shared.verify(signature: signature, nonce: nonce, for: senderIP) {
            logger.info("SignalingServer: auto-accepting ring from trusted caller \(senderIP)")
            let sessionId = client.accept()
            let descriptor = SessionDescriptor(
                sessionId: sessionId,
                peerIP: senderIP,
                videoPort: 5535,
                audioPort: 5536,
                controlPort: 5537
            )
            let intent = ring.intent
            Task { @MainActor in
                self.delegate?.signalingServer(self, autoAcceptedRingFrom: peer, descriptor: descriptor, intent: intent)
            }
        } else {
            Task { @MainActor in
                self.delegate?.signalingServer(self, receivedRingFrom: peer, client: client, intent: ring.intent)
            }
        }
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
