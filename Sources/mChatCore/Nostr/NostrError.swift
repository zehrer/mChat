import Foundation

public enum NostrError: Error, LocalizedError, Sendable {
    case invalidPrivateKey
    case invalidPublicKey
    case signingFailed
    case encryptionFailed
    case decryptionFailed
    case invalidEventJSON
    case relayNotConnected
    case relayConnectionFailed(URL)
    case keychainError(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:          return "Invalid private key"
        case .invalidPublicKey:           return "Invalid public key"
        case .signingFailed:              return "Failed to sign event"
        case .encryptionFailed:           return "Encryption failed"
        case .decryptionFailed:           return "Decryption failed"
        case .invalidEventJSON:           return "Invalid event JSON"
        case .relayNotConnected:          return "Relay is not connected"
        case .relayConnectionFailed(let url): return "Failed to connect to relay: \(url)"
        case .keychainError(let status):  return "Keychain error: \(status)"
        }
    }
}
