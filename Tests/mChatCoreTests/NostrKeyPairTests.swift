import XCTest
@testable import mChatCore

final class NostrKeyPairTests: XCTestCase {

    func testKeyGeneration() throws {
        let kp = try NostrKeyPair()
        XCTAssertEqual(kp.privateKeyBytes.count, 32)
        XCTAssertEqual(kp.publicKeyBytes.count,  32)
        XCTAssertEqual(kp.privateKeyHex.count,   64)
        XCTAssertEqual(kp.publicKeyHex.count,    64)
    }

    func testRoundTripFromHex() throws {
        let original = try NostrKeyPair()
        let restored = try NostrKeyPair(privateKeyHex: original.privateKeyHex)
        XCTAssertEqual(original.privateKeyHex, restored.privateKeyHex)
        XCTAssertEqual(original.publicKeyHex,  restored.publicKeyHex)
    }

    func testDeterministicPublicKey() throws {
        // Same private key must always produce the same public key
        let kp1 = try NostrKeyPair()
        let kp2 = try NostrKeyPair(privateKeyBytes: kp1.privateKeyBytes)
        XCTAssertEqual(kp1.publicKeyHex, kp2.publicKeyHex)
    }

    func testECDH_symmetry() throws {
        let alice = try NostrKeyPair()
        let bob   = try NostrKeyPair()

        let aliceSecret = try alice.ecdhSharedSecret(with: bob.publicKeyHex)
        let bobSecret   = try bob.ecdhSharedSecret(with: alice.publicKeyHex)

        XCTAssertEqual(aliceSecret, bobSecret, "ECDH shared secrets must match")
        XCTAssertEqual(aliceSecret.count, 32)
    }
}

final class NostrEventTests: XCTestCase {

    func testEventIdLength() throws {
        let kp = try NostrKeyPair()
        let event = try NostrEvent.build(kind: 1, tags: [], content: "hello", keyPair: kp)
        XCTAssertEqual(event.id.count,     64)
        XCTAssertEqual(event.sig.count,    128)
        XCTAssertEqual(event.pubkey.count, 64)
    }
}

final class NIP04Tests: XCTestCase {

    func testEncryptDecryptRoundTrip() throws {
        let alice = try NostrKeyPair()
        let bob   = try NostrKeyPair()

        let message = "Hello, private world!"
        let cipher  = try NIP04.encrypt(
            plaintext: message,
            senderPrivkey: alice.privateKeyBytes,
            recipientPubkeyHex: bob.publicKeyHex
        )

        let plain = try NIP04.decrypt(
            ciphertext: cipher,
            recipientPrivkey: bob.privateKeyBytes,
            senderPubkeyHex: alice.publicKeyHex
        )

        XCTAssertEqual(plain, message)
    }

    func testCiphertextFormat() throws {
        let alice  = try NostrKeyPair()
        let bob    = try NostrKeyPair()
        let cipher = try NIP04.encrypt(
            plaintext: "test",
            senderPrivkey: alice.privateKeyBytes,
            recipientPubkeyHex: bob.publicKeyHex
        )
        XCTAssertTrue(cipher.contains("?iv="), "NIP-04 wire format must contain ?iv= separator")
    }
}

final class DataExtensionTests: XCTestCase {

    func testHexRoundTrip() {
        let original = Data([0x00, 0xde, 0xad, 0xbe, 0xef, 0xff])
        XCTAssertEqual(original.hexString, "00deadbeefff")
        XCTAssertEqual(Data(hexString: original.hexString), original)
    }

    func testInvalidHex() {
        XCTAssertNil(Data(hexString: "xyz"))
        XCTAssertNil(Data(hexString: "abc"))  // odd length
    }
}
