import Foundation

/// A decrypted chat message, protocol-agnostic.
public struct ChatMessage: Identifiable, Sendable, Codable, Equatable {
    public let id: String               // Protocol-native message ID
    public let conversationId: String   // Parent Conversation.id
    public let senderIdentifier: String // Protocol-native sender ID
    public let content: String          // Decrypted plaintext (or rich text in future)
    public let timestamp: Date
    public let fromMe: Bool
    public var deliveryStatus: DeliveryStatus
    public let `protocol`: ChatProtocol

    public enum DeliveryStatus: String, Codable, Sendable, Equatable {
        case sending, sent, delivered, read, failed
    }

    public init(
        id: String,
        conversationId: String,
        senderIdentifier: String,
        content: String,
        timestamp: Date,
        fromMe: Bool,
        deliveryStatus: DeliveryStatus = .sent,
        protocol: ChatProtocol
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderIdentifier = senderIdentifier
        self.content = content
        self.timestamp = timestamp
        self.fromMe = fromMe
        self.deliveryStatus = deliveryStatus
        self.`protocol` = `protocol`
    }
}

// MARK: - Nostr convenience

extension ChatMessage {
    /// Creates a ChatMessage from a NIP-04 DM event.
    public static func fromNostrDM(
        event: NostrEvent,
        myPubkeyHex: String,
        myPrivkeyBytes: Data
    ) throws -> ChatMessage {
        let fromMe = event.pubkey == myPubkeyHex
        let otherPubkey = fromMe
            ? (event.tagValue("p") ?? "")
            : event.pubkey

        let plaintext = try NIP04.decrypt(
            ciphertext: event.content,
            recipientPrivkey: myPrivkeyBytes,
            senderPubkeyHex: fromMe ? otherPubkey : event.pubkey
        )

        let conv = Conversation(protocol: .nostr, type: .oneToOne(peerIdentifier: otherPubkey))

        return ChatMessage(
            id: event.id,
            conversationId: conv.id,
            senderIdentifier: event.pubkey,
            content: plaintext,
            timestamp: event.date,
            fromMe: fromMe,
            protocol: .nostr
        )
    }
}
