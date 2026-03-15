import Foundation

// MARK: - Top-level status response

struct TailscaleStatus: Codable {
    let selfNode: TailscaleSelf
    let peer: [String: TailscalePeer]?

    enum CodingKeys: String, CodingKey {
        case selfNode = "Self"
        case peer = "Peer"
    }
}

struct TailscaleSelf: Codable {
    let hostName: String
    let dnsName: String?
    let tailscaleIPs: [String]?
    let online: Bool?
    let userID: Int?

    enum CodingKeys: String, CodingKey {
        case hostName = "HostName"
        case dnsName = "DNSName"
        case tailscaleIPs = "TailscaleIPs"
        case online = "Online"
        case userID = "UserID"
    }
}

struct TailscalePeer: Codable {
    let id: String?
    let hostName: String
    let dnsName: String?
    let tailscaleIPs: [String]?
    let online: Bool?
    let os: String?
    let userID: Int?
    let lastSeen: String?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case hostName = "HostName"
        case dnsName = "DNSName"
        case tailscaleIPs = "TailscaleIPs"
        case online = "Online"
        case os = "OS"
        case userID = "UserID"
        case lastSeen = "LastSeen"
    }

    /// Primary Tailscale IP (100.x.x.x)
    var primaryIP: String? {
        tailscaleIPs?.first(where: { $0.hasPrefix("100.") })
    }
}

// MARK: - PearPeer: a Tailscale peer that is running PearShare

struct PearPeer: Identifiable, Equatable {
    let id: String           // Tailscale host key (stable)
    let hostName: String
    let displayName: String
    let tailscaleIP: String
    let platform: String
    let appVersion: String
    var status: PearStatus
    var lastSeen: Date

    static func == (lhs: PearPeer, rhs: PearPeer) -> Bool {
        lhs.id == rhs.id
    }
}

enum PearStatus: String, Codable {
    case available
    case busy
    case dnd
}
