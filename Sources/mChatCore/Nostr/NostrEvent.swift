import Foundation
import CryptoKit

// MARK: - Event kinds (NIP-01, NIP-04)

public enum NostrKind: Int, Codable, Sendable {
    case metadata         = 0   // NIP-01 user profile
    case textNote         = 1   // NIP-01 plaintext note
    case encryptedDM      = 4   // NIP-04 encrypted direct message
    case repost           = 6   // NIP-18
    case reaction         = 7   // NIP-25
    case channelMessage   = 42  // NIP-28
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

    // MARK: - Private helpers

    /// Creates, signs, and returns a new event with a computed ID.
    public static func build(
        kind: Int,
        tags: [[String]],
        content: String,
        keyPair: NostrKeyPair
    ) throws -> NostrEvent {
        let timestamp = Int(Date().timeIntervalSince1970)

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
    private static func canonical(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        tags: [[String]],
        content: String
    ) throws -> String {
        let tagsArray = tags as NSArray
        let tagsData = try JSONSerialization.data(withJSONObject: tagsArray,
                                                   options: [.sortedKeys])
        let tagsStr = String(data: tagsData, encoding: .utf8)!
        // Escape content string for embedding in JSON without a full serializer
        let escapedContent = content.jsonStringEscaped
        return "[0,\"\(pubkey)\",\(createdAt),\(kind),\(tagsStr),\"\(escapedContent)\"]"
    }
}
