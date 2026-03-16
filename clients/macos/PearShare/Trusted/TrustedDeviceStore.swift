import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "TrustedDeviceStore")

// MARK: - TrustedDevice

/// A peer device that has been permanently authorized to ring this machine and
/// start a screen-share session without any confirmation prompt.
struct TrustedDevice: Codable, Identifiable {
    /// The peer's Tailscale IP address (used as the stable key for lookups).
    let peerID: String
    let displayName: String
    /// 32-byte random hex token — shared secret between both parties.
    let token: String
    let grantedAt: Date

    var id: String { peerID }
}

// MARK: - TrustedDeviceStore

/// Persists trusted device records in UserDefaults.
///
/// Role on the **granting machine** (the one that will auto-answer):
///   - `grant()` stores a record so incoming rings can be validated.
///   - `isTokenValid()` is called by SignalingServer to silently accept matching rings.
///
/// Role on the **calling machine** (the one that will initiate auto-sessions):
///   - `grant()` also stores a record (same call, different perspective — they store
///     the token they received via TrustGrantMessage so they can include it in rings).
///   - `token(for:)` is called by SignalingClient.sendRing() to attach the token.
final class TrustedDeviceStore {

    static let shared = TrustedDeviceStore()
    private init() {}

    private let defaultsKey = "com.pearshare.trustedDevices"

    // MARK: - Read

    var all: [TrustedDevice] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let devices = try? JSONDecoder().decode([TrustedDevice].self, from: data) else {
            return []
        }
        return devices
    }

    /// Returns the stored token for a given peer ID, if one exists.
    /// Called by the caller (viewer) side to include in a ring.
    func token(for peerID: String) -> String? {
        all.first(where: { $0.peerID == peerID })?.token
    }

    /// Returns whether `token` is the valid shared secret for `peerID`.
    /// Called by SignalingServer on the host side when a ring arrives.
    func isTokenValid(_ token: String, for peerID: String) -> Bool {
        guard let stored = all.first(where: { $0.peerID == peerID }) else { return false }
        // Constant-time comparison to avoid timing attacks (token is security-sensitive)
        return stored.token == token
    }

    func isTrusted(peerID: String) -> Bool {
        all.contains(where: { $0.peerID == peerID })
    }

    // MARK: - Write

    func grant(_ device: TrustedDevice) {
        var current = all
        // Replace any existing entry for this peer
        current.removeAll(where: { $0.peerID == device.peerID })
        current.append(device)
        save(current)
        logger.info("TrustedDeviceStore: granted trust to \(device.displayName) (\(device.peerID))")
    }

    func revoke(peerID: String) {
        var current = all
        current.removeAll(where: { $0.peerID == peerID })
        save(current)
        logger.info("TrustedDeviceStore: revoked trust for \(peerID)")
    }

    // MARK: - Private

    private func save(_ devices: [TrustedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Token generation

    /// Generates a cryptographically random 32-byte hex token.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
