import Foundation
import SwiftData

@Model
final class StoredConversation {
    @Attribute(.unique) var id: String
    var protocolRaw: String
    var typeRaw: String            // "oneToOne" | "group"
    var peerIdentifier: String?    // set when typeRaw == "oneToOne"
    var groupId: String?           // set when typeRaw == "group"
    var groupName: String?         // set when typeRaw == "group"
    var isPinned: Bool
    var isMuted: Bool
    var lastMessageTimestamp: Date?

    init(from conv: Conversation) {
        id          = conv.id
        protocolRaw = conv.protocol.rawValue
        isPinned    = conv.isPinned
        isMuted     = conv.isMuted
        lastMessageTimestamp = conv.lastMessage?.timestamp

        switch conv.type {
        case .oneToOne(let peer):
            typeRaw        = "oneToOne"
            peerIdentifier = peer
        case .group(let gid, let name):
            typeRaw   = "group"
            groupId   = gid
            groupName = name
        }
    }

    func toConversation() -> Conversation? {
        guard let proto = ChatProtocol(rawValue: protocolRaw) else { return nil }

        let type: ConversationType
        switch typeRaw {
        case "oneToOne":
            guard let peer = peerIdentifier else { return nil }
            type = .oneToOne(peerIdentifier: peer)
        case "group":
            guard let gid = groupId, let name = groupName else { return nil }
            type = .group(groupIdentifier: gid, name: name)
        default:
            return nil
        }

        return Conversation(protocol: proto, type: type, isPinned: isPinned, isMuted: isMuted)
    }
}
