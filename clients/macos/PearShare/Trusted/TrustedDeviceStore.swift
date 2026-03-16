import Foundation
import CryptoKit
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "TrustedDeviceStore")

// MARK: - TrustedDevice

/// A peer we allow to auto-connect to us: we store their public key. When they ring
/// and prove they hold the matching private key (sign our nonce), we auto-accept.
struct TrustedDevice: Codable, Identifiable {
    let peerID: String
    let displayName: String
    /// Ed25519 public key (base64) — we only store this; they prove identity by signing.
    let publicKey: String
    let grantedAt: Date

    var id: String { peerID }
}

// MARK: - TrustedDeviceStore

/// Persists trusted callers by public key. Trust is one-sided: when you add a peer's
/// pubkey, you will auto-answer when they ring and prove identity. Revoke only removes
/// from your list; nothing is sent to the other device.
final class TrustedDeviceStore {

    static let shared = TrustedDeviceStore()
    private init() {}

    private let defaultsKey = "com.pearshare.trustedCallers"

    var all: [TrustedDevice] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let devices = try? JSONDecoder().decode([TrustedDevice].self, from: data) else {
            return []
        }
        return devices
    }

    func isTrusted(peerID: String) -> Bool {
        all.contains(where: { $0.peerID == peerID })
    }

    /// Returns the stored public key (raw bytes) for a peer, if any.
    func publicKeyData(for peerID: String) -> Data? {
        guard let b64 = all.first(where: { $0.peerID == peerID })?.publicKey else { return nil }
        return Data(base64Encoded: b64)
    }

    /// Verifies that `signature` (raw 64 bytes) is valid for `nonce` (raw bytes) using
    /// the stored public key for `peerID`. Used by SignalingServer when a ring arrives.
    func verify(signature: Data, nonce: Data, for peerID: String) -> Bool {
        guard let pubKey = publicKeyData(for: peerID) else { return false }
        return IdentityStore.verify(signature: signature, data: nonce, publicKey: pubKey)
    }

    func grant(_ device: TrustedDevice) {
        var current = all
        current.removeAll(where: { $0.peerID == device.peerID })
        current.append(device)
        save(current)
        logger.info("TrustedDeviceStore: granted auto-answer to \(device.displayName) (\(device.peerID))")
    }

    func revoke(peerID: String) {
        var current = all
        current.removeAll(where: { $0.peerID == peerID })
        save(current)
        logger.info("TrustedDeviceStore: revoked auto-answer for \(peerID)")
    }

    private func save(_ devices: [TrustedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
