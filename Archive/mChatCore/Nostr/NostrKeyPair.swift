import Foundation
import secp256k1
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A Nostr identity: secp256k1 keypair using Schnorr signing (BIP-340).
/// The public key is the 32-byte x-only representation as required by NIP-01.
public struct NostrKeyPair: Sendable {

    public let privateKeyBytes: Data   // 32 bytes
    public let publicKeyBytes: Data    // 32 bytes, x-only

    public var privateKeyHex: String { privateKeyBytes.hexString }
    public var publicKeyHex: String  { publicKeyBytes.hexString }

    @preconcurrency private let signingKey: secp256k1.Schnorr.PrivateKey

    // MARK: - Init

    public init() throws {
        let key = try secp256k1.Schnorr.PrivateKey()
        try self.init(rawPrivateKey: Data(key.dataRepresentation))
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
        signingKey = key
        privateKeyBytes = Data(key.dataRepresentation)
        // xonly gives the 32-byte x-coordinate (no compression prefix), as Nostr requires
        publicKeyBytes = Data(key.xonly.bytes)
    }

    // MARK: - Signing

    /// Signs a 32-byte event ID with Schnorr (BIP-340) as required by NIP-01.
    public func sign(eventId: Data) throws -> String {
        guard eventId.count == 32 else { throw NostrError.signingFailed }
        var hashBytes = Array(eventId)
        var auxRand = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        let signature = try signingKey.signature(message: &hashBytes, auxiliaryRand: &auxRand)
        return Data(signature.dataRepresentation).hexString
    }

    // MARK: - ECDH

    /// Returns the 32-byte shared secret for NIP-04 encryption.
    /// Uses the x-coordinate of the ECDH shared point directly (no KDF), per NIP-04 spec.
    public func ecdhSharedSecret(with recipientPubkeyHex: String) throws -> Data {
        guard let recipientXOnly = Data(hexString: recipientPubkeyHex) else {
            throw NostrError.invalidPublicKey
        }
        // Add a 02 compression prefix to turn x-only → compressed pubkey
        let compressed = Data([0x02]) + recipientXOnly
        let privKey = try secp256k1.KeyAgreement.PrivateKey(dataRepresentation: privateKeyBytes)
        let pubKey = try secp256k1.KeyAgreement.PublicKey(dataRepresentation: compressed)
        let secret = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
        return secret.withUnsafeBytes { Data($0) }
    }
}
