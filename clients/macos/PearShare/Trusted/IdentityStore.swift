import Foundation
import CryptoKit
import Security
import OSLog

private let logger = Logger(subsystem: "com.pearshare.app", category: "IdentityStore")

// MARK: - IdentityStore

/// Holds this device's long-lived Ed25519 keypair. The public key is advertised
/// in the presence beacon so peers can add it when they "trust" us. The private
/// key is used to sign ring nonces so we can prove identity when calling.
final class IdentityStore {

    static let shared = IdentityStore()
    private static let keychainService = "com.pearshare.identity"
    private static let keychainAccount = "signing-key"

    private let key: Curve25519.Signing.PrivateKey

    private init() {
        if let existing = Self.loadFromKeychain() {
            self.key = existing
            logger.info("IdentityStore: loaded existing key")
        } else {
            let newKey = Curve25519.Signing.PrivateKey()
            self.key = newKey
            Self.saveToKeychain(newKey)
            logger.info("IdentityStore: generated new key")
        }
    }

    /// Raw 32-byte public key for advertising in the beacon (base64-encoded on the wire).
    var publicKeyData: Data {
        key.publicKey.rawRepresentation
    }

    /// Base64-encoded public key for JSON/beacon.
    var publicKeyBase64: String {
        publicKeyData.base64EncodedString()
    }

    /// Sign data (e.g. a nonce) for inclusion in a ring. Returns raw 64-byte signature.
    func sign(_ data: Data) -> Data? {
        try? key.signature(for: data)
    }

    /// Verify a signature over data using a peer's public key (raw 32 bytes).
    static func verify(signature: Data, data: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    // MARK: - Keychain

    private static func loadFromKeychain() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        return key
    }

    private static func saveToKeychain(_ key: Curve25519.Signing.PrivateKey) {
        let data = key.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary) // ignore errors
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("IdentityStore: failed to save key to Keychain: \(status)")
        }
    }
}
