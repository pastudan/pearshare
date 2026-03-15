import Foundation
import Network
import Combine

// MARK: - PeerStore (observable state)

@MainActor
final class PeerStore: ObservableObject {
    @Published var peers: [PearPeer] = []
    @Published var tailscaleOnline: Bool = false
    @Published var selfHostName: String = ""

    func upsert(_ peer: PearPeer) {
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
        }
    }

    func remove(id: String) {
        peers.removeAll { $0.id == id }
    }

    func markStale(before date: Date) {
        peers.removeAll { $0.lastSeen < date }
    }
}

// MARK: - PeerDiscovery

/// Combines two signals to build the peer list:
/// 1. Tailscale LocalAPI polling — tells us which devices are online in the tailnet
/// 2. UDP beacon reception on port 5533 — tells us which devices are running PearShare
final class PeerDiscovery {
    private let tailscaleClient: TailscaleClient
    private let peerStore: PeerStore
    private let beaconPort: UInt16 = 5533

    private var pollTask: Task<Void, Never>?
    private var beaconListener: NWListener?
    private var beaconSendTimer: Timer?

    // Tracks which Tailscale IPs are currently reachable per LocalAPI
    private var tailscaleOnlinePeers: [String: TailscalePeer] = [:]

    init(tailscaleClient: TailscaleClient, peerStore: PeerStore) {
        self.tailscaleClient = tailscaleClient
        self.peerStore = peerStore
    }

    func start() {
        startPolling()
        startBeaconListener()
        startBeaconSender()
    }

    func stop() {
        pollTask?.cancel()
        beaconListener?.cancel()
        beaconSendTimer?.invalidate()
    }

    // MARK: - Tailscale Polling

    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                await pollTailscale()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func pollTailscale() async {
        do {
            let status = try await tailscaleClient.status()
            await MainActor.run {
                peerStore.tailscaleOnline = true
                peerStore.selfHostName = status.selfNode.hostName
            }

            // Update our map of online Tailscale peers
            var updated: [String: TailscalePeer] = [:]
            for (_, peer) in status.peer ?? [:] {
                guard let ip = peer.primaryIP, peer.online == true else { continue }
                updated[ip] = peer
            }
            tailscaleOnlinePeers = updated

            // Prune PearPeers that are no longer online in Tailscale
            let onlineIPs = Set(updated.keys)
            await MainActor.run {
                peerStore.peers.removeAll { !onlineIPs.contains($0.tailscaleIP) }
            }
        } catch {
            await MainActor.run { peerStore.tailscaleOnline = false }
            print("[PeerDiscovery] Tailscale poll failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UDP Beacon Listener (receive beacons from peers)

    private func startBeaconListener() {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: beaconPort)!) else {
            print("[PeerDiscovery] Failed to bind beacon listener on port \(beaconPort)")
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .background))
            self?.receiveBeacon(from: connection)
        }

        listener.start(queue: .global(qos: .background))
        beaconListener = listener
    }

    private func receiveBeacon(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, let data, error == nil else { return }

            // Determine sender IP from the connection endpoint
            var senderIP: String?
            if case .hostPort(let host, _) = connection.endpoint {
                senderIP = "\(host)"
            }

            self.handleBeacon(data: data, fromIP: senderIP)

            // Keep receiving from this connection (UDP "connections" are per-datagram but NWListener reuses them)
            self.receiveBeacon(from: connection)
        }
    }

    private func handleBeacon(data: Data, fromIP: String?) {
        guard let fromIP else { return }

        // Only accept beacons from peers that Tailscale considers online
        guard tailscaleOnlinePeers[fromIP] != nil else { return }

        guard let beacon = try? JSONDecoder().decode(PresenceBeacon.self, from: data),
              beacon.v == 1,
              beacon.type == "presence" else { return }

        let tsPeer = tailscaleOnlinePeers[fromIP]

        let pearPeer = PearPeer(
            id: fromIP, // use IP as stable ID for now; could use Tailscale node key
            hostName: tsPeer?.hostName ?? fromIP,
            displayName: beacon.displayName,
            tailscaleIP: fromIP,
            platform: beacon.platform,
            appVersion: beacon.appVersion,
            status: PearStatus(rawValue: beacon.status) ?? .available,
            lastSeen: Date()
        )

        Task { @MainActor in
            self.peerStore.upsert(pearPeer)
        }
    }

    // MARK: - UDP Beacon Sender (announce ourselves to peers)

    private func startBeaconSender() {
        beaconSendTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.sendBeacon()
        }
        beaconSendTimer?.fire()
    }

    private func sendBeacon() {
        let beacon = PresenceBeacon(
            v: 1,
            type: "presence",
            status: "available",
            displayName: Host.current().localizedName ?? "PearShare User",
            platform: "macos",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        guard let data = try? JSONEncoder().encode(beacon) else { return }

        // Send to all currently known Tailscale online peers
        for (ip, _) in tailscaleOnlinePeers {
            sendUDP(data: data, toIP: ip, port: beaconPort)
        }
    }

    private func sendUDP(data: Data, toIP: String, port: UInt16) {
        let connection = NWConnection(
            host: NWEndpoint.Host(toIP),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        connection.start(queue: .global(qos: .background))
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Beacon Payload

struct PresenceBeacon: Codable {
    let v: Int
    let type: String
    let status: String
    let displayName: String
    let platform: String
    let appVersion: String
}
