import Foundation
import Security
import mChatCore

/// Manages the user's Nostr identity. The private key is stored in the iOS Keychain.
/// The public key (safe to persist plainly) is stored in UserDefaults.
@MainActor
public final class IdentityService: ObservableObject {

    public static let shared = IdentityService()

    @Published public private(set) var keyPair: NostrKeyPair?
    @Published public private(set) var profile: Contact?

    private let keychainService = "net.zehrer.mChat"
    private let keychainAccount = "nostr-private-key"
    private let profileKey = "mChat.profile"

    private init() {
        keyPair = loadKeyPairFromKeychain()
        profile = loadProfile()
    }

    // MARK: - Identity creation / import

    public func createNewIdentity() throws {
        let kp = try NostrKeyPair()
        try saveToKeychain(privateKeyBytes: kp.privateKeyBytes)
        keyPair = kp
    }

    public func importIdentity(privateKeyHex: String) throws {
        let kp = try NostrKeyPair(privateKeyHex: privateKeyHex)
        try saveToKeychain(privateKeyBytes: kp.privateKeyBytes)
        keyPair = kp
    }

    public func deleteIdentity() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        keyPair = nil
        profile = nil
        UserDefaults.standard.removeObject(forKey: profileKey)
    }

    // MARK: - Profile

    public func updateProfile(_ contact: Contact) {
        profile = contact
        if let data = try? JSONEncoder().encode(contact) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    // MARK: - Keychain

    private func loadKeyPairFromKeychain() -> NostrKeyPair? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainService,
            kSecAttrAccount as String:      keychainAccount,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? NostrKeyPair(privateKeyBytes: data)
    }

    private func saveToKeychain(privateKeyBytes: Data) throws {
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      keychainService,
            kSecAttrAccount as String:      keychainAccount,
            kSecValueData as String:        privateKeyBytes,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NostrError.keychainError(status)
        }
    }

    private func loadProfile() -> Contact? {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(Contact.self, from: data)
    }
}
