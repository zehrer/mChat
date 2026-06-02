import Foundation
import secp256k1
import Crypto
import _CryptoExtras

/// NIP-44 v2 encrypted payloads (used by NIP-17 sealed-sender DMs).
///
/// Algorithm: ChaCha20-CTR stream cipher + HMAC-SHA256 authentication tag.
/// Key derivation: HKDF-SHA256 over the secp256k1 ECDH shared x-coordinate.
/// Wire format: base64(version(1) || nonce(32) || ciphertext || mac(32))
public enum NIP44 {

    private static let versionByte: UInt8 = 2

    // MARK: - Public API

    public static func encrypt(
        plaintext: String,
        senderPrivkey: Data,
        recipientPubkeyHex: String
    ) throws -> String {
        let convKey = try conversationKey(privateKey: senderPrivkey, pubkeyHex: recipientPubkeyHex)
        let nonce = randomBytes(32)
        let keys = messageKeys(conversationKey: convKey, nonce: nonce)
        let padded = pad(plaintext)
        let ciphertext = try chacha20(padded, key: keys.chacha, nonce: keys.nonce)
        let mac = computeHMAC(nonce: nonce, ciphertext: ciphertext, key: keys.hmac)
        return (Data([versionByte]) + nonce + ciphertext + mac).base64EncodedString()
    }

    public static func decrypt(
        payload: String,
        recipientPrivkey: Data,
        senderPubkeyHex: String
    ) throws -> String {
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            throw NostrError.decryptionFailed
        }
        // version(1) + nonce(32) + min_padded_ciphertext(34) + mac(32) = 99 bytes minimum
        guard data.count >= 99, data[0] == versionByte else { throw NostrError.decryptionFailed }
        let nonce      = Data(data[1..<33])
        let ciphertext = Data(data[33..<(data.count - 32)])
        let receivedMAC = Data(data[(data.count - 32)...])

        let convKey = try conversationKey(privateKey: recipientPrivkey, pubkeyHex: senderPubkeyHex)
        let keys = messageKeys(conversationKey: convKey, nonce: nonce)

        guard verifyHMAC(nonce: nonce, ciphertext: ciphertext,
                         key: keys.hmac, expected: receivedMAC
        ) else { throw NostrError.decryptionFailed }

        let padded = try chacha20(ciphertext, key: keys.chacha, nonce: keys.nonce)
        return try unpad(padded)
    }

    // MARK: - Key derivation

    // Decrypt using a pre-derived conversation key — used for spec vector tests.
    static func decryptWithConversationKey(payload: String, conversationKey: Data) throws -> String {
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
            throw NostrError.decryptionFailed
        }
        guard data.count >= 99, data[0] == versionByte else { throw NostrError.decryptionFailed }
        let nonce       = Data(data[1..<33])
        let ciphertext  = Data(data[33..<(data.count - 32)])
        let receivedMAC = Data(data[(data.count - 32)...])
        let keys = messageKeys(conversationKey: conversationKey, nonce: nonce)
        guard verifyHMAC(nonce: nonce, ciphertext: ciphertext,
                         key: keys.hmac, expected: receivedMAC
        ) else { throw NostrError.decryptionFailed }
        let padded = try chacha20(ciphertext, key: keys.chacha, nonce: keys.nonce)
        return try unpad(padded)
    }

    // Internal so NostrEvent can reuse it for gift-wrap ephemeral keys if needed.
    static func conversationKey(privateKey: Data, pubkeyHex: String) throws -> Data {
        guard let xOnly = Data(hexString: pubkeyHex) else { throw NostrError.invalidPublicKey }
        let compressed = Data([0x02]) + xOnly
        let priv = try secp256k1.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        let pub  = try secp256k1.KeyAgreement.PublicKey(dataRepresentation: compressed)
        let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
        // drop 0x02/03 prefix — keep only the 32-byte x-coordinate
        let sharedX = secret.withUnsafeBytes { Data($0).dropFirst() }
        // HKDF-Extract: PRK = HMAC-SHA256(salt="nip44-v2", IKM=sharedX)
        // Use Crypto.HKDF to avoid ambiguity with secp256k1.SHA256
        let prk = SymmetricKey(data: Crypto.HKDF<Crypto.SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: sharedX),
            salt: Data("nip44-v2".utf8)
        ))
        return prk.withUnsafeBytes { Data($0) }
    }

    private struct MessageKeys {
        let chacha: Data  // 32 bytes — ChaCha20-CTR key
        let nonce:  Data  // 12 bytes — ChaCha20-CTR nonce
        let hmac:   Data  // 32 bytes — HMAC-SHA256 key
    }

    private static func messageKeys(conversationKey: Data, nonce: Data) -> MessageKeys {
        // HKDF-Expand: keys = HKDF(PRK=conversationKey, info=nonce, len=76)
        let expanded = Crypto.HKDF<Crypto.SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: conversationKey),
            info: nonce,
            outputByteCount: 76
        )
        let b = expanded.withUnsafeBytes { Data($0) }
        return MessageKeys(chacha: b[0..<32], nonce: b[32..<44], hmac: b[44..<76])
    }

    // MARK: - ChaCha20-CTR (symmetric: same function for encrypt and decrypt)

    private static func chacha20(_ data: Data, key: Data, nonce: Data) throws -> Data {
        let chaNonce = try Insecure.ChaCha20CTR.Nonce(data: nonce)
        return try Insecure.ChaCha20CTR.encrypt(data, using: SymmetricKey(data: key), nonce: chaNonce)
    }

    // MARK: - HMAC-SHA256

    private static func computeHMAC(nonce: Data, ciphertext: Data, key: Data) -> Data {
        // NIP-44 spec: MAC = HMAC-SHA256(key=hmac_key, data=nonce || ciphertext)
        let msg = nonce + ciphertext
        let code = Crypto.HMAC<Crypto.SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return Data(code)
    }

    private static func verifyHMAC(nonce: Data, ciphertext: Data, key: Data, expected: Data) -> Bool {
        let msg = nonce + ciphertext
        return Crypto.HMAC<Crypto.SHA256>.isValidAuthenticationCode(expected, authenticating: msg, using: SymmetricKey(data: key))
    }

    // MARK: - Padding (NIP-44 v2 spec)
    // Wire: 2-byte BE length prefix + message bytes + zero padding to calcPaddedLen(len)

    private static func calcPaddedLen(_ len: Int) -> Int {
        if len <= 32 { return 32 }
        let bits = Int(ceil(log2(Double(len))))
        let nextPow = 1 << (bits + 1)
        let chunk = nextPow / 8
        return chunk * ((len - 1) / chunk + 1)
    }

    private static func pad(_ plaintext: String) -> Data {
        let bytes = Data(plaintext.utf8)
        let len = bytes.count
        var out = Data(capacity: 2 + calcPaddedLen(len))
        out.append(UInt8(len >> 8))
        out.append(UInt8(len & 0xFF))
        out.append(contentsOf: bytes)
        out.append(contentsOf: repeatElement(0, count: calcPaddedLen(len) - len))
        return out
    }

    private static func unpad(_ data: Data) throws -> String {
        guard data.count >= 2 else { throw NostrError.decryptionFailed }
        let len = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        let msgStart = data.startIndex + 2
        let msgEnd = msgStart + len
        guard data.endIndex >= msgEnd else { throw NostrError.decryptionFailed }
        guard let text = String(data: data[msgStart..<msgEnd], encoding: .utf8) else {
            throw NostrError.decryptionFailed
        }
        return text
    }

    // MARK: - Helpers

    private static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min...(.max)) })
    }
}
