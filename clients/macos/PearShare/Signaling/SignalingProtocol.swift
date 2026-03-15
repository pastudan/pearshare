import Foundation

// MARK: - Message types (matches protocol/PROTOCOL.md §2)

enum SignalingMessageType: String, Codable {
    case ring
    case accept
    case reject
    case hangup
    case busy
}

// MARK: - Outbound messages (we send these)

struct RingMessage: Codable {
    let type: String = "ring"
    let from: String
    let displayName: String
    let tailscaleIP: String
    let version: String
}

struct AcceptMessage: Codable {
    let type: String = "accept"
    let sessionId: String
    let videoPort: Int
    let audioPort: Int
    let controlPort: Int
}

struct RejectMessage: Codable {
    let type: String = "reject"
    let reason: String
}

struct HangupMessage: Codable {
    let type: String = "hangup"
}

struct BusyMessage: Codable {
    let type: String = "busy"
}

// MARK: - Inbound message envelope (decode type field first)

struct SignalingEnvelope: Codable {
    let type: String
}

// MARK: - Session descriptor (returned in ACCEPT)

struct SessionDescriptor {
    let sessionId: String
    let peerIP: String
    let videoPort: Int
    let audioPort: Int
    let controlPort: Int
}
