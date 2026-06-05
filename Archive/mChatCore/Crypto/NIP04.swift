import Foundation
import secp256k1
#if canImport(CommonCrypto)
import CommonCrypto
#else
import Crypto
import _CryptoExtras
#endif

/// NIP-04 encrypted direct messages.
///
/// Encryption scheme: AES-256-CBC with a random IV.
/// Key derivation: raw x-coordinate of the ECDH shared point (no KDF).
/// Wire format: base64(ciphertext) + "?iv=" + base64(iv)
///
/// Note: NIP-44 supersedes NIP-04 with stronger privacy (sealed sender).
/// NIP-04 is implemented here for broad relay compatibility. Upgrade path
/// is to replace this module with a NIP-44 implementation.
public enum NIP04 {

    // MARK: - Public API

    public static func encrypt(
        plaintext: String,
        senderPrivkey: Data,
        recipientPubkeyHex: String
    ) throws -> String {
        let key = try sharedKey(privateKey: senderPrivkey, recipientPubkeyHex: recipientPubkeyHex)
        let iv = randomBytes(count: 16)
        let plainData = plaintext.data(using: .utf8) ?? Data()
        let cipher = try aesCBC(.encrypt, data: plainData, key: key, iv: iv)
        return "\(cipher.base64EncodedString())?iv=\(iv.base64EncodedString())"
    }

    public static func decrypt(
        ciphertext: String,
        recipientPrivkey: Data,
        senderPubkeyHex: String
    ) throws -> String {
        let parts = ciphertext.components(separatedBy: "?iv=")
        guard
            parts.count == 2,
            let cipher = Data(base64Encoded: parts[0]),
            let iv     = Data(base64Encoded: parts[1])
        else { throw NostrError.decryptionFailed }

        let key   = try sharedKey(privateKey: recipientPrivkey, recipientPubkeyHex: senderPubkeyHex)
        let plain = try aesCBC(.decrypt, data: cipher, key: key, iv: iv)
        guard let result = String(data: plain, encoding: .utf8) else {
            throw NostrError.decryptionFailed
        }
        return result
    }

    // MARK: - Private helpers

    private static func randomBytes(count: Int) -> Data {
        #if canImport(CommonCrypto)
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
        #else
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
        #endif
    }

    private static func sharedKey(privateKey: Data, recipientPubkeyHex: String) throws -> Data {
        guard let xOnly = Data(hexString: recipientPubkeyHex) else {
            throw NostrError.invalidPublicKey
        }
        // Prepend 02 to turn x-only → compressed pubkey for secp256k1 key agreement.
        let compressed = Data([0x02]) + xOnly
        let priv = try secp256k1.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        let pub  = try secp256k1.KeyAgreement.PublicKey(dataRepresentation: compressed)
        let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
        // sharedSecretFromKeyAgreement returns 33 bytes (compressed: 0x02/03 prefix + 32-byte x-coord).
        // NIP-04 uses only the x-coordinate as the 32-byte AES-256 key.
        return secret.withUnsafeBytes { Data($0).dropFirst() }
    }

    private enum AESOperation { case encrypt, decrypt }

    private static func aesCBC(
        _ op: AESOperation,
        data: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        #if canImport(CommonCrypto)
        let ccOp = CCOperation(op == .encrypt ? kCCEncrypt : kCCDecrypt)
        var outLen = 0
        var outBuf = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)

        let status = data.withUnsafeBytes { dataBuf in
            key.withUnsafeBytes { keyBuf in
                iv.withUnsafeBytes { ivBuf in
                    CCCrypt(
                        ccOp,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuf.baseAddress, key.count,
                        ivBuf.baseAddress,
                        dataBuf.baseAddress, data.count,
                        &outBuf, outBuf.count,
                        &outLen
                    )
                }
            }
        }

        guard status == CCCryptorStatus(kCCSuccess) else {
            throw op == .encrypt ? NostrError.encryptionFailed : NostrError.decryptionFailed
        }
        return Data(outBuf.prefix(outLen))
        #else
        let symmetricKey = SymmetricKey(data: key)
        let aesIV = try AES._CBC.IV(ivBytes: Array(iv))
        switch op {
        case .encrypt:
            return try AES._CBC.encrypt(data, using: symmetricKey, iv: aesIV)
        case .decrypt:
            return try AES._CBC.decrypt(data, using: symmetricKey, iv: aesIV)
        }
        #endif
    }
}
