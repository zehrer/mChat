import Foundation

/// A Nostr contact derived from a kind-0 metadata event.
public struct Contact: Identifiable, Sendable, Codable, Equatable {
    public let pubkeyHex: String   // 32-byte hex — the canonical identity
    public var displayName: String?
    public var about: String?
    public var pictureURL: URL?
    public var nip05: String?      // NIP-05 identifier: name@domain.com
    public var lastSeen: Date?

    public var id: String { pubkeyHex }

    /// Short display name falls back to a truncated pubkey.
    public var name: String {
        displayName ?? String(pubkeyHex.prefix(8)) + "…"
    }

    /// NIP-05 verification status (resolved externally).
    public var isVerified: Bool { nip05 != nil }

    public init(pubkeyHex: String) {
        self.pubkeyHex = pubkeyHex
    }

    /// Parses a kind-0 metadata event into a Contact.
    public static func from(metadataEvent event: NostrEvent) -> Contact? {
        guard event.kind == NostrKind.metadata.rawValue else { return nil }
        var contact = Contact(pubkeyHex: event.pubkey)
        guard
            let data   = event.content.data(using: .utf8),
            let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return contact }

        contact.displayName = fields["name"]       as? String
                           ?? fields["display_name"] as? String
        contact.about       = fields["about"]      as? String
        contact.nip05       = fields["nip05"]      as? String
        if let pic = fields["picture"] as? String { contact.pictureURL = URL(string: pic) }
        contact.lastSeen = event.date
        return contact
    }
}
