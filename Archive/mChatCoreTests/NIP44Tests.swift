import XCTest
import Crypto
@testable import mChatCore

final class NIP44Tests: XCTestCase {

    // Official NIP-44 v2 test vectors — conversation_key
    // https://github.com/paulmillr/nip44/blob/main/nip44.vectors.json
    func testConversationKey() throws {
        let cases: [(sec1: String, pub2: String, expected: String)] = [
            ("315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268",
             "c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133",
             "3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1"),
            ("a1e37752c9fdc1273be53f68c5f74be7c8905728e8de75800b94262f9497c86e",
             "03bb7947065dde12ba991ea045132581d0954f042c84e06d8c00066e23c1a800",
             "4d14f36e81b8452128da64fe6f1eae873baae2f444b02c950b90e43553f2178b"),
            ("98a5902fd67518a0c900f0fb62158f278f94a21d6f9d33d30cd3091195500311",
             "aae65c15f98e5e677b5050de82e3aba47a6fe49b3dab7863cf35d9478ba9f7d1",
             "9c00b769d5f54d02bf175b7284a1cbd28b6911b06cda6666b2243561ac96bad7"),
            ("86ae5ac8034eb2542ce23ec2f84375655dab7f836836bbd3c54cefe9fdc9c19f",
             "59f90272378089d73f1339710c02e2be6db584e9cdbe86eed3578f0c67c23585",
             "19f934aafd3324e8415299b64df42049afaa051c71c98d0aa10e1081f2e3e2ba"),
            ("2528c287fe822421bc0dc4c3615878eb98e8a8c31657616d08b29c00ce209e34",
             "f66ea16104c01a1c532e03f166c5370a22a5505753005a566366097150c6df60",
             "c833bbb292956c43366145326d53b955ffb5da4e4998a2d853611841903f5442"),
        ]

        for (i, tc) in cases.enumerated() {
            let privData = Data(hexString: tc.sec1)!
            let got = try NIP44.conversationKey(privateKey: privData, pubkeyHex: tc.pub2)
            XCTAssertEqual(got.hexString, tc.expected,
                           "conversation_key mismatch for test case \(i + 1)")
        }
    }

    // Official NIP-44 v2 test vectors — full encrypt/decrypt payloads.
    // These vectors use a fixed nonce, so we can verify the exact wire payload.
    func testDecryptVectors() throws {
        let cases: [(convKey: String, nonce: String, plaintext: String, payload: String)] = [
            (
                "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d",
                "0000000000000000000000000000000000000000000000000000000000000001",
                "a",
                "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"
            ),
            (
                "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d",
                "f00000000000000000000000000000f00000000000000000000000000000000f",
                "🍕🫃",
                "AvAAAAAAAAAAAAAAAAAAAPAAAAAAAAAAAAAAAAAAAAAPSKSK6is9ngkX2+cSq85Th16oRTISAOfhStnixqZziKMDvB0QQzgFZdjLTPicCJaV8nDITO+QfaQ61+KbWQIOO2Yj"
            ),
            (
                "3e2b52a63be47d34fe0a80e34e73d436d6963bc8f39827f327057a9986c20a45",
                "b635236c42db20f021bb8d1cdff5ca75dd1a0cc72ea742ad750f33010b24f73b",
                "表ポあA鷗ŒéＢ逍Üßªąñ丂㐀𠀀",
                "ArY1I2xC2yDwIbuNHN/1ynXdGgzHLqdCrXUPMwELJPc7s7JqlCMJBAIIjfkpHReBPXeoMCyuClwgbT419jUWU1PwaNl4FEQYKCDKVJz+97Mp3K+Q2YGa77B6gpxB/lr1QgoqpDf7wDVrDmOqGoiPjWDqy8KzLueKDcm9BVP8xeTJIxs="
            ),
        ]

        for (i, tc) in cases.enumerated() {
            let convKey = Data(hexString: tc.convKey)!
            let decrypted = try NIP44.decryptWithConversationKey(payload: tc.payload, conversationKey: convKey)
            XCTAssertEqual(decrypted, tc.plaintext,
                           "decrypt mismatch for test case \(i + 1)")
        }
    }

    // Round-trip: encrypt then decrypt should return the original plaintext
    func testRoundTrip() throws {
        let alicePriv = Data(hexString: "315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268")!
        let aliceKeyPair = try NostrKeyPair(privateKeyBytes: alicePriv)
        let bobPriv  = Data(hexString: "a1e37752c9fdc1273be53f68c5f74be7c8905728e8de75800b94262f9497c86e")!
        let bobKeyPair   = try NostrKeyPair(privateKeyBytes: bobPriv)

        let plaintext = "Hello, NIP-44!"
        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivkey: alicePriv,
            recipientPubkeyHex: bobKeyPair.publicKeyHex
        )
        let decrypted = try NIP44.decrypt(
            payload: encrypted,
            recipientPrivkey: bobPriv,
            senderPubkeyHex: aliceKeyPair.publicKeyHex
        )
        XCTAssertEqual(decrypted, plaintext)
    }
}
