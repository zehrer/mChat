import Foundation

// MARK: - Protocol identifier

/// Identifies the underlying chat protocol backing a conversation.
/// New protocols (Matrix, Telegram, XMPP, …) add a case here.
public enum ChatProtocol: String, Codable, Sendable, CaseIterable {
    case nostr
    case matrix
    case xmpp
    // Add more as backends are implemented
}

// MARK: - Conversation type

public enum ConversationType: Sendable, Codable, Equatable {
    /// Direct one-to-one chat. `peerIdentifier` is protocol-specific
    /// (e.g. Nostr pubkey hex, Matrix user ID like @user:server.org).
    case oneToOne(peerIdentifier: String)
    /// Group chat. `groupIdentifier` is protocol-specific
    /// (e.g. Nostr channel ID, Matrix room ID like !room:server.org).
    case group(groupIdentifier: String, name: String)
}

// MARK: - Conversation

/// A conversation backed by any supported protocol.
public struct Conversation: Identifiable, Sendable, Codable, Equatable {
    /// Stable local identifier: "<protocol>:<type-specific-id>"
    public let id: String
    public let `protocol`: ChatProtocol
    public let type: ConversationType
    public var lastMessage: ChatMessage?
    public var unreadCount: Int
    public var isPinned: Bool
    public var isMuted: Bool

    public var displayName: String {
        switch type {
        case .oneToOne(let peer):  return peer  // overridden by ContactStore lookup
        case .group(_, let name):  return name
        }
    }

    public var isGroup: Bool {
        if case .group = type { return true }
        return false
    }

    public init(
        protocol: ChatProtocol,
        type: ConversationType,
        unreadCount: Int = 0,
        isPinned: Bool = false,
        isMuted: Bool = false
    ) {
        let typeId: String
        switch type {
        case .oneToOne(let p):     typeId = p
        case .group(let g, _):    typeId = g
        }
        self.id = "\(`protocol`.rawValue):\(typeId)"
        self.`protocol` = `protocol`
        self.type = type
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.isMuted = isMuted
    }
}
