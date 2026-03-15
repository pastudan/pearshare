import Foundation
import Network

// MARK: - Delegate

@MainActor
protocol SignalingServerDelegate: AnyObject {
    func signalingServer(_ server: SignalingServer, receivedRingFrom peer: PearPeer, client: SignalingClient)
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
            print("[SignalingServer] Failed to bind on port \(Self.port)")
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[SignalingServer] Listening on port \(Self.port)")
            case .failed(let error):
                print("[SignalingServer] Listener failed: \(error)")
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
        readLine(from: connection) { [weak self] data in
            guard let self, let data else { return }
            self.processFirstMessage(data: data, connection: connection)
        }
    }

    private func processFirstMessage(data: Data, connection: NWConnection) {
        guard let envelope = try? JSONDecoder().decode(SignalingEnvelope.self, from: data),
              envelope.type == "ring",
              let ring = try? JSONDecoder().decode(RingMessage.self, from: data) else {
            connection.cancel()
            return
        }

        // Build a PearPeer from the ring message (they might not be in our beacon list yet)
        let senderIP = extractIP(from: connection.endpoint) ?? ring.tailscaleIP
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

        // Wrap connection in a SignalingClient so the delegate can send responses
        let client = SignalingClient(existingConnection: connection, peer: peer)

        Task { @MainActor in
            self.delegate?.signalingServer(self, receivedRingFrom: peer, client: client)
        }
    }

    private func readLine(from connection: NWConnection, completion: @escaping (Data?) -> Void) {
        // Read until newline delimiter
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            guard error == nil, let data, !data.isEmpty else {
                completion(nil)
                return
            }
            // Strip trailing newline
            let trimmed = data.trimmingNewline()
            completion(trimmed)
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
