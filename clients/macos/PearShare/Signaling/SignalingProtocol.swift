import Foundation

// MARK: - Message types (matches protocol/PROTOCOL.md §2)

enum SignalingMessageType: String, Codable {
    case ring
    case accept
    case reject
    case hangup
    case busy
    case trustGrant  // out-of-band: granter pushes a trust token to the grantee
}

// MARK: - Outbound messages (we send these)

struct RingMessage: Codable {
    let type: String = "ring"
    let from: String
    let displayName: String
    let tailscaleIP: String
    let version: String
    /// Present when the caller holds a valid trust token for this peer.
    /// Ignored by peers that don't support trusted-device auto-answer.
    let trustedToken: String?
    /// "share" = caller is sharing their screen to the callee (callee watches).
    /// "request" = caller is asking the callee to share their screen (caller watches).
    /// Defaults to "share" for backwards compatibility with older clients.
    let intent: String

    init(from: String, displayName: String, tailscaleIP: String, version: String,
         trustedToken: String? = nil, intent: String = "share") {
        self.from = from
        self.displayName = displayName
        self.tailscaleIP = tailscaleIP
        self.version = version
        self.trustedToken = trustedToken
        self.intent = intent
    }
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

/// Sent by the granting machine to the peer it has just trusted.
/// The peer stores the token so it can include it in future RingMessages.
struct TrustGrantMessage: Codable {
    let type: String = "trustGrant"
    let token: String
    let granterDisplayName: String
    let granterPeerID: String  // granter's Tailscale IP — used as the key on the receiving side
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
