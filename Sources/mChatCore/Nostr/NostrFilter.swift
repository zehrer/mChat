import Foundation

/// A subscription filter sent to a relay (NIP-01 REQ message).
public struct NostrFilter: Codable, Sendable {
    public var ids: [String]?
    public var authors: [String]?
    public var kinds: [Int]?
    public var since: Int?
    public var until: Int?
    public var limit: Int?
    public var tags: [String: [String]]?   // "#p": ["pubkey", ...]

    enum CodingKeys: String, CodingKey {
        case ids, authors, kinds, since, until, limit
    }

    public init(
        ids: [String]? = nil,
        authors: [String]? = nil,
        kinds: [Int]? = nil,
        since: Int? = nil,
        until: Int? = nil,
        limit: Int? = nil
    ) {
        self.ids = ids
        self.authors = authors
        self.kinds = kinds
        self.since = since
        self.until = until
        self.limit = limit
    }

    // Custom encoding to include dynamic tag keys (#p, #e, etc.)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        if let ids      { try container.encode(ids,     forKey: .init("ids")) }
        if let authors  { try container.encode(authors, forKey: .init("authors")) }
        if let kinds    { try container.encode(kinds,   forKey: .init("kinds")) }
        if let since    { try container.encode(since,   forKey: .init("since")) }
        if let until    { try container.encode(until,   forKey: .init("until")) }
        if let limit    { try container.encode(limit,   forKey: .init("limit")) }
        if let tags {
            for (key, values) in tags {
                try container.encode(values, forKey: .init(key))
            }
        }
    }
}

// MARK: - Convenience factories

extension NostrFilter {
    /// Subscribes to all incoming NIP-04 DMs for the given pubkey.
    public static func incomingDMs(for pubkeyHex: String, since: Int? = nil) -> NostrFilter {
        var f = NostrFilter(kinds: [NostrKind.encryptedDM.rawValue], since: since, limit: 100)
        f.tags = ["#p": [pubkeyHex]]
        return f
    }

    /// Subscribes to all outgoing NIP-04 DMs sent by the given pubkey.
    public static func outgoingDMs(from pubkeyHex: String, since: Int? = nil) -> NostrFilter {
        NostrFilter(authors: [pubkeyHex], kinds: [NostrKind.encryptedDM.rawValue], since: since, limit: 100)
    }

    /// Subscribes to metadata (kind 0) for a list of pubkeys.
    public static func metadata(for pubkeys: [String]) -> NostrFilter {
        NostrFilter(authors: pubkeys, kinds: [NostrKind.metadata.rawValue], limit: pubkeys.count)
    }
}

// MARK: - DynamicKey helper

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
