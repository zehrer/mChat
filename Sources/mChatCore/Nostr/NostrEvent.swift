import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Event kinds (NIP-01, NIP-04, NIP-17)

public enum NostrKind: Int, Codable, Sendable {
    case metadata         = 0     // NIP-01 user profile
    case textNote         = 1     // NIP-01 plaintext note
    case encryptedDM      = 4     // NIP-04 encrypted direct message
    case repost           = 6     // NIP-18
    case reaction         = 7     // NIP-25
    case seal             = 13    // NIP-17 sealed sender
    case relayList        = 10002 // NIP-65 relay list
    case giftWrap         = 1059  // NIP-17 gift-wrap outer envelope
    case channelMessage   = 42    // NIP-28
}

// MARK: - NostrEvent

/// An immutable, signed Nostr event (NIP-01).
public struct NostrEvent: Codable, Sendable, Identifiable {
    public let id: String        // 32-byte hex SHA256 of the canonical serialization
    public let pubkey: String    // 32-byte hex x-only public key of the author
    public let createdAt: Int    // Unix timestamp (seconds)
    public let kind: Int         // Event kind integer
    public let tags: [[String]]  // Ordered tag arrays
    public let content: String   // Arbitrary string content
    public let sig: String       // 64-byte hex Schnorr signature

    enum CodingKeys: String, CodingKey {
        case id, pubkey, content, sig, kind, tags
        case createdAt = "created_at"
    }

    /// Returns the first value of the tag with the given name, if present.
    public func tagValue(_ name: String) -> String? {
        tags.first { $0.first == name }?.dropFirst().first
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
}

// MARK: - Event construction

extension NostrEvent {

    /// Creates and signs a NIP-04 encrypted direct message.
    public static func encryptedDM(
        content: String,
        recipientPubkey: String,
        keyPair: NostrKeyPair
    ) throws -> NostrEvent {
        let encrypted = try NIP04.encrypt(
            plaintext: content,
            senderPrivkey: keyPair.privateKeyBytes,
            recipientPubkeyHex: recipientPubkey
        )
        return try build(
            kind: NostrKind.encryptedDM.rawValue,
            tags: [["p", recipientPubkey]],
            content: encrypted,
            keyPair: keyPair
        )
    }

    /// Creates and signs a kind-0 metadata (profile) event.
    public static func metadata(
        name: String,
        about: String?,
        picture: String?,
        nip05: String?,
        keyPair: NostrKeyPair
    ) throws -> NostrEvent {
        var fields: [String: String] = ["name": name]
        if let about  { fields["about"]   = about }
        if let picture { fields["picture"] = picture }
        if let nip05  { fields["nip05"]   = nip05 }
        let json = try JSONSerialization.data(withJSONObject: fields)
        let content = String(data: json, encoding: .utf8)!
        return try build(kind: NostrKind.metadata.rawValue, tags: [], content: content, keyPair: keyPair)
    }

    /// Creates and signs a kind-10002 relay list event (NIP-65).
    /// Tells other clients which relays to use when sending to this identity.
    public static func relayList(relays: [URL], keyPair: NostrKeyPair) throws -> NostrEvent {
        let tags = relays.map { ["r", $0.absoluteString] }
        return try build(kind: NostrKind.relayList.rawValue, tags: tags, content: "", keyPair: keyPair)
    }

    // MARK: - Private helpers

    /// Creates, signs, and returns a new event with a computed ID.
    public static func build(
        kind: Int,
        tags: [[String]],
        content: String,
        keyPair: NostrKeyPair,
        createdAt: Int? = nil
    ) throws -> NostrEvent {
        let timestamp = createdAt ?? Int(Date().timeIntervalSince1970)

        let serialized = try canonical(
            pubkey: keyPair.publicKeyHex,
            createdAt: timestamp,
            kind: kind,
            tags: tags,
            content: content
        )

        let idData = Data(SHA256.hash(data: serialized.data(using: .utf8)!))
        let id = idData.hexString
        let sig = try keyPair.sign(eventId: idData)

        return NostrEvent(
            id: id,
            pubkey: keyPair.publicKeyHex,
            createdAt: timestamp,
            kind: kind,
            tags: tags,
            content: content,
            sig: sig
        )
    }

    /// Produces the canonical JSON string that is hashed to form the event ID (NIP-01).
    static func canonical(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        tags: [[String]],
        content: String
    ) throws -> String {
        let tagsArray = tags as NSArray
        let tagsData = try JSONSerialization.data(withJSONObject: tagsArray,
                                                   options: [.sortedKeys])
        // Strip `\/` → `/`: Linux JSONSerialization escapes forward slashes, but relays
        // (Go/JS) don't — causing hash mismatches. Forward slashes need no escaping in JSON.
        let tagsStr = String(data: tagsData, encoding: .utf8)!
            .replacingOccurrences(of: "\\/", with: "/")
        // Escape content string for embedding in JSON without a full serializer
        let escapedContent = content.jsonStringEscaped
        return "[0,\"\(pubkey)\",\(createdAt),\(kind),\(tagsStr),\"\(escapedContent)\"]"
    }
}

// MARK: - NIP-17 gift-wrap (sealed-sender DMs)

extension NostrEvent {

    // Result from unwrapping a gift-wrap chain.
    public struct UnwrappedDM: Sendable {
        public let senderPubkey: String
        public let recipientPubkey: String
        public let content: String
        public let timestamp: Date
        public let rumorId: String
    }

    /// Builds the full NIP-17 gift-wrap chain for a DM:
    ///   rumor (kind:14, unsigned) → seal (kind:13) → gift-wrap (kind:1059)
    /// Returns the outermost kind:1059 event ready to publish.
    public static func giftWrap(
        content: String,
        recipientPubkey: String,
        keyPair: NostrKeyPair
    ) throws -> NostrEvent {
        let rumorJson = try makeRumorJSON(content: content, recipientPubkey: recipientPubkey, keyPair: keyPair)
        let seal = try makeSeal(rumorJson: rumorJson, recipientPubkey: recipientPubkey, keyPair: keyPair)
        let sealJson = String(data: try JSONEncoder().encode(seal), encoding: .utf8)!
        return try makeGiftWrap(sealJson: sealJson, recipientPubkey: recipientPubkey)
    }

    /// Unwraps a kind:1059 gift-wrap event, returning the inner DM details.
    public static func unwrapGiftWrap(
        event: NostrEvent,
        myPubkeyHex: String,
        myPrivkeyBytes: Data
    ) throws -> UnwrappedDM {
        guard event.kind == NostrKind.giftWrap.rawValue else { throw NostrError.invalidEventJSON }

        // Layer 1: decrypt outer gift-wrap using our key + ephemeral pubkey
        let sealJson = try NIP44.decrypt(
            payload: event.content,
            recipientPrivkey: myPrivkeyBytes,
            senderPubkeyHex: event.pubkey  // ephemeral key
        )
        guard let sealData = sealJson.data(using: .utf8),
              let seal = try? JSONDecoder().decode(NostrEvent.self, from: sealData),
              seal.kind == NostrKind.seal.rawValue
        else { throw NostrError.decryptionFailed }

        // Layer 2: decrypt seal using our key + real sender pubkey
        let rumorJson = try NIP44.decrypt(
            payload: seal.content,
            recipientPrivkey: myPrivkeyBytes,
            senderPubkeyHex: seal.pubkey  // real sender
        )
        guard let rumorData = rumorJson.data(using: .utf8),
              let rumor = try? JSONDecoder().decode(NostrEvent.self, from: rumorData),
              rumor.kind == 14
        else { throw NostrError.decryptionFailed }

        let recipientPubkey = rumor.tagValue("p") ?? myPubkeyHex
        return UnwrappedDM(
            senderPubkey: seal.pubkey,
            recipientPubkey: recipientPubkey,
            content: rumor.content,
            timestamp: rumor.date,
            rumorId: rumor.id
        )
    }

    // MARK: - Private NIP-17 helpers

    private static func makeRumorJSON(
        content: String,
        recipientPubkey: String,
        keyPair: NostrKeyPair
    ) throws -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let tags = [["p", recipientPubkey]]
        let serial = try canonical(pubkey: keyPair.publicKeyHex, createdAt: ts, kind: 14, tags: tags, content: content)
        let idData = Data(SHA256.hash(data: serial.data(using: .utf8)!))
        let id = idData.hexString
        // Rumor is unsigned — sig is absent (serialized as empty string so it decodes cleanly)
        let rumor = NostrEvent(id: id, pubkey: keyPair.publicKeyHex, createdAt: ts, kind: 14,
                               tags: tags, content: content, sig: "")
        return String(data: try JSONEncoder().encode(rumor), encoding: .utf8)!
    }

    private static func makeSeal(
        rumorJson: String,
        recipientPubkey: String,
        keyPair: NostrKeyPair
    ) throws -> NostrEvent {
        let encrypted = try NIP44.encrypt(
            plaintext: rumorJson,
            senderPrivkey: keyPair.privateKeyBytes,
            recipientPubkeyHex: recipientPubkey
        )
        // Randomize created_at up to 2 days in the past to obscure timing (NIP-17 requirement)
        let ts = Int(Date().timeIntervalSince1970) - Int.random(in: 0...172800)
        return try build(kind: NostrKind.seal.rawValue, tags: [], content: encrypted,
                         keyPair: keyPair, createdAt: ts)
    }

    private static func makeGiftWrap(sealJson: String, recipientPubkey: String) throws -> NostrEvent {
        let ephemeralKeyPair = try NostrKeyPair()
        let encrypted = try NIP44.encrypt(
            plaintext: sealJson,
            senderPrivkey: ephemeralKeyPair.privateKeyBytes,
            recipientPubkeyHex: recipientPubkey
        )
        let ts = Int(Date().timeIntervalSince1970) - Int.random(in: 0...172800)
        return try build(kind: NostrKind.giftWrap.rawValue,
                         tags: [["p", recipientPubkey]],
                         content: encrypted,
                         keyPair: ephemeralKeyPair,
                         createdAt: ts)
    }
}
