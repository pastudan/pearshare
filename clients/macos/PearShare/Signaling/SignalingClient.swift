import Foundation
import Network
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "SignalingClient")

// MARK: - Outcomes

enum RingOutcome {
    case accepted(SessionDescriptor)
    case rejected(reason: String)
    case busy
    case timeout
    case error(Error)
}

// MARK: - SignalingClient

/// Used for both:
/// - Outbound rings (we dial the peer's port 5534)
/// - Responding to inbound rings (server hands us the already-connected NWConnection)
/// - Sending trust grant messages to a peer
final class SignalingClient {
    private let peer: PearPeer
    private weak var peerStore: PeerStore?
    private var connection: NWConnection?

    private var ringContinuation: CheckedContinuation<RingOutcome, Never>?

    /// Called on the main actor when the remote side accepts the ring.
    @MainActor var onAccepted: ((SessionDescriptor) -> Void)?

    // Outbound: create a fresh connection
    init(peer: PearPeer, peerStore: PeerStore?) {
        self.peer = peer
        self.peerStore = peerStore
    }

    // Inbound: server passes us the already-accepted connection
    init(existingConnection: NWConnection, peer: PearPeer) {
        self.peer = peer
        self.connection = existingConnection
    }

    // MARK: - Outbound call

    /// Dials the peer and sends RING. Delivers outcome via `onAccepted` callback or logs other outcomes.
    func ring() {
        Task {
            let outcome = await dial()
            switch outcome {
            case .accepted(let session):
                await MainActor.run { self.onAccepted?(session) }
            case .rejected(let reason):
                logger.info("SignalingClient: call rejected: \(reason)")
            case .busy:
                logger.info("SignalingClient: peer is busy")
            case .timeout:
                logger.info("SignalingClient: ring timed out")
            case .error(let e):
                logger.error("SignalingClient: ring error: \(e)")
            }
        }
    }

    private func dial() async -> RingOutcome {
        let conn = NWConnection(
            host: NWEndpoint.Host(peer.tailscaleIP),
            port: NWEndpoint.Port(rawValue: SignalingServer.port)!,
            using: .tcp
        )
        self.connection = conn

        return await withCheckedContinuation { continuation in
            self.ringContinuation = continuation

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendRing()
                    self.listenForResponse()
                case .failed(let error):
                    self.ringContinuation?.resume(returning: .error(error))
                    self.ringContinuation = nil
                case .cancelled:
                    break
                default:
                    break
                }
            }

            conn.start(queue: .global(qos: .userInitiated))

            // 35-second timeout (peer UI auto-declines at 30s)
            Task {
                try? await Task.sleep(for: .seconds(35))
                if self.ringContinuation != nil {
                    conn.cancel()
                    self.ringContinuation?.resume(returning: .timeout)
                    self.ringContinuation = nil
                }
            }
        }
    }

    private var ringIntent: String = "share"

    private func sendRing() {
        // Include a trusted token if we hold one for this peer — enables auto-accept on their end
        let token = TrustedDeviceStore.shared.token(for: peer.id)
        let msg = RingMessage(
            from: Host.current().localizedName ?? "PearShare",
            displayName: Host.current().localizedName ?? "PearShare",
            tailscaleIP: "", // filled by receiver from connection
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            trustedToken: token,
            intent: ringIntent
        )
        send(msg)
    }

    /// Send a ring with intent = "request" (asking the peer to share their screen to us).
    func ringAsRequest() {
        ringIntent = "request"
        ring()
    }

    private func listenForResponse() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                self.ringContinuation?.resume(returning: .error(error))
                self.ringContinuation = nil
                return
            }

            guard let data, let trimmed = data.nonEmpty else { return }
            self.processResponse(data: trimmed)
        }
    }

    private func processResponse(data: Data) {
        guard let envelope = try? JSONDecoder().decode(SignalingEnvelope.self, from: data) else { return }

        switch envelope.type {
        case "accept":
            guard let accept = try? JSONDecoder().decode(AcceptMessage.self, from: data) else { return }
            let session = SessionDescriptor(
                sessionId: accept.sessionId,
                peerIP: peer.tailscaleIP,
                videoPort: accept.videoPort,
                audioPort: accept.audioPort,
                controlPort: accept.controlPort
            )
            ringContinuation?.resume(returning: .accepted(session))
            ringContinuation = nil

        case "reject":
            let msg = (try? JSONDecoder().decode(RejectMessage.self, from: data))
            ringContinuation?.resume(returning: .rejected(reason: msg?.reason ?? "declined"))
            ringContinuation = nil

        case "busy":
            ringContinuation?.resume(returning: .busy)
            ringContinuation = nil

        default:
            break
        }
    }

    // MARK: - Inbound: callee responses

    func accept() {
        let sessionId = UUID().uuidString
        let msg = AcceptMessage(
            sessionId: sessionId,
            videoPort: 5535,
            audioPort: 5536,
            controlPort: 5537
        )
        send(msg)
    }

    func reject(reason: String) {
        send(RejectMessage(reason: reason))
        connection?.cancel()
    }

    func hangup() {
        send(HangupMessage())
        connection?.cancel()
    }

    // MARK: - Trust grant

    /// Opens a short-lived TCP connection to the peer and sends a TrustGrantMessage.
    /// This tells the peer "I have trusted you; here is the token to include in future rings to me."
    ///
    /// - Parameters:
    ///   - token: The shared secret to send (stored on both sides).
    ///   - myDisplayName: Our display name, shown in the peer's trusted-devices list.
    ///   - myPeerID: Our Tailscale IP, used as the key on the peer's side.
    func sendTrustGrant(token: String, myDisplayName: String, myPeerID: String) {
        let conn = NWConnection(
            host: NWEndpoint.Host(peer.tailscaleIP),
            port: NWEndpoint.Port(rawValue: SignalingServer.port)!,
            using: .tcp
        )

        conn.stateUpdateHandler = { [weak conn] state in
            switch state {
            case .ready:
                let msg = TrustGrantMessage(
                    token: token,
                    granterDisplayName: myDisplayName,
                    granterPeerID: myPeerID
                )
                guard var data = try? JSONEncoder().encode(msg) else { return }
                data.append(0x0A)
                conn?.send(content: data, completion: .contentProcessed { _ in
                    conn?.cancel()
                })
            case .failed(let error):
                logger.error("SignalingClient: trust grant send failed: \(error)")
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        logger.info("SignalingClient: sending trust grant to \(self.peer.tailscaleIP)")
    }

    // MARK: - Send helper

    private func send<T: Encodable>(_ message: T) {
        guard let connection,
              var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A) // newline delimiter
        connection.send(content: data, completion: .idempotent)
    }
}

// MARK: - Data helper

private extension Data {
    var nonEmpty: Data? { isEmpty ? nil : self }
}
