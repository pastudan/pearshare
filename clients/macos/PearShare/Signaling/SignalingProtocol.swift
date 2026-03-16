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
    let type: String
    let from: String
    let displayName: String
    let tailscaleIP: String
    let version: String
    /// "share" = caller is sharing their screen to the callee (callee watches).
    /// "request" = caller is asking the callee to share their screen (caller watches).
    let intent: String
    /// Caller-generated nonce (base64), signed with caller's private key for auto-answer verification.
    let nonce: String?
    /// Ed25519 signature over nonce (base64). Callee verifies with stored pubkey for caller.
    let signature: String?

    init(from: String, displayName: String, tailscaleIP: String, version: String,
         intent: String = "share", nonce: String? = nil, signature: String? = nil) {
        self.type = "ring"
        self.from = from
        self.displayName = displayName
        self.tailscaleIP = tailscaleIP
        self.version = version
        self.intent = intent
        self.nonce = nonce
        self.signature = signature
    }
}

struct AcceptMessage: Codable {
    let type: String
    let sessionId: String
    let videoPort: Int
    let audioPort: Int
    let controlPort: Int

    init(sessionId: String, videoPort: Int, audioPort: Int, controlPort: Int) {
        self.type = "accept"
        self.sessionId = sessionId
        self.videoPort = videoPort
        self.audioPort = audioPort
        self.controlPort = controlPort
    }
}

struct RejectMessage: Codable {
    let type: String
    let reason: String

    init(reason: String) {
        self.type = "reject"
        self.reason = reason
    }
}

struct HangupMessage: Codable {
    let type: String

    init() { self.type = "hangup" }
}

struct BusyMessage: Codable {
    let type: String

    init() { self.type = "busy" }
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
