import Foundation
import SwiftData

@Model
final class StoredMessage {
    @Attribute(.unique) var id: String
    var conversationId: String
    var senderIdentifier: String
    var content: String
    var timestamp: Date
    var fromMe: Bool
    var deliveryStatusRaw: String
    var protocolRaw: String

    init(from msg: ChatMessage) {
        id               = msg.id
        conversationId   = msg.conversationId
        senderIdentifier = msg.senderIdentifier
        content          = msg.content
        timestamp        = msg.timestamp
        fromMe           = msg.fromMe
        deliveryStatusRaw = msg.deliveryStatus.rawValue
        protocolRaw      = msg.protocol.rawValue
    }

    func toChatMessage() -> ChatMessage {
        ChatMessage(
            id: id,
            conversationId: conversationId,
            senderIdentifier: senderIdentifier,
            content: content,
            timestamp: timestamp,
            fromMe: fromMe,
            deliveryStatus: .init(rawValue: deliveryStatusRaw) ?? .sent,
            protocol: .init(rawValue: protocolRaw) ?? .nostr
        )
    }
}
