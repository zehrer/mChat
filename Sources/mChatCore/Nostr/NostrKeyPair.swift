import Foundation
import secp256k1
import CryptoKit

/// A Nostr identity: secp256k1 keypair using Schnorr signing (BIP-340).
/// The public key is the 32-byte x-only representation as required by NIP-01.
public struct NostrKeyPair: Sendable {

    public let privateKeyBytes: Data   // 32 bytes
    public let publicKeyBytes: Data    // 32 bytes, x-only

    public var privateKeyHex: String { privateKeyBytes.hexString }
    public var publicKeyHex: String  { publicKeyBytes.hexString }

    // MARK: - Init

    public init() throws {
        let key = try secp256k1.Schnorr.PrivateKey()
        try self.init(rawPrivateKey: key.dataRepresentation)
    }

    public init(privateKeyHex: String) throws {
        guard let bytes = Data(hexString: privateKeyHex) else {
            throw NostrError.invalidPrivateKey
        }
        try self.init(rawPrivateKey: bytes)
    }

    public init(privateKeyBytes: Data) throws {
        try self.init(rawPrivateKey: privateKeyBytes)
    }

    private init(rawPrivateKey bytes: Data) throws {
        let key = try secp256k1.Schnorr.PrivateKey(dataRepresentation: bytes)
        privateKeyBytes = bytes
        publicKeyBytes = Data(key.xonly.bytes)
    }

    // MARK: - Signing

    /// Signs a 32-byte event ID with Schnorr (BIP-340) as required by NIP-01.
    public func sign(eventId: Data) throws -> String {
        guard eventId.count == 32 else { throw NostrError.signingFailed }
        let signingKey = try secp256k1.Schnorr.PrivateKey(dataRepresentation: privateKeyBytes)
        var eventBytes = [UInt8](eventId)
        let signature = try signingKey.signature(
            message: &eventBytes,
            auxiliaryRand: nil,
            strict: true
        )
        return signature.dataRepresentation.hexString
    }

    // MARK: - ECDH

    /// Returns the 32-byte shared secret for NIP-04 encryption.
    /// Uses the x-coordinate of the ECDH point directly (no KDF), per NIP-04 spec.
    public func ecdhSharedSecret(with recipientPubkeyHex: String) throws -> Data {
        guard let recipientXOnly = Data(hexString: recipientPubkeyHex) else {
            throw NostrError.invalidPublicKey
        }
        // Add a 02 compression prefix to turn x-only → compressed pubkey
        let compressed = Data([0x02]) + recipientXOnly
        let privKey = try secp256k1.KeyAgreement.PrivateKey(dataRepresentation: privateKeyBytes)
        let pubKey = try secp256k1.KeyAgreement.PublicKey(dataRepresentation: compressed)
        let secret = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
        return secret.withUnsafeBytes { Data($0.dropFirst()) }
    }
}
