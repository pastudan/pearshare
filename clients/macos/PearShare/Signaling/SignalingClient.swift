import Foundation
import Network
import Security
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
        // Prove identity for auto-answer: sign a nonce so callee can verify with our pubkey
        var nonceB64: String?
        var sigB64: String?
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, 32, &nonceBytes) == errSecSuccess {
            let nonce = Data(nonceBytes)
            if let sig = IdentityStore.shared.sign(nonce) {
                nonceB64 = nonce.base64EncodedString()
                sigB64 = sig.base64EncodedString()
            }
        }
        let msg = RingMessage(
            from: Host.current().localizedName ?? "PearShare",
            displayName: Host.current().localizedName ?? "PearShare",
            tailscaleIP: "",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            intent: ringIntent,
            nonce: nonceB64,
            signature: sigB64
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

    @discardableResult
    func accept(sessionId: String = UUID().uuidString) -> String {
        let msg = AcceptMessage(
            sessionId: sessionId,
            videoPort: 5535,
            audioPort: 5536,
            controlPort: 5537
        )
        send(msg)
        return sessionId
    }

    func reject(reason: String) {
        send(RejectMessage(reason: reason))
        connection?.cancel()
    }

    func hangup() {
        send(HangupMessage())
        connection?.cancel()
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
