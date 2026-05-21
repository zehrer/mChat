import Foundation
import SwiftData
import mChatCore

/// Thin SwiftData wrapper — all access must happen on the MainActor
/// since we use the container's mainContext exclusively.
@MainActor
final class MessageStore {

    static let shared = MessageStore()

    private let container: ModelContainer

    private var context: ModelContext { container.mainContext }

    private init() {
        do {
            let schema = Schema([
                StoredMessage.self,
                StoredConversation.self,
                StoredContact.self,
            ])
            container = try ModelContainer(for: schema)
        } catch {
            // A failure here means the on-disk schema is incompatible.
            // In production, add a migration plan instead of crashing.
            fatalError("SwiftData container failed to initialise: \(error)")
        }
    }

    // MARK: - Messages

    func save(_ message: ChatMessage) throws {
        let id = message.id
        let existing = try fetch(StoredMessage.self, where: #Predicate { $0.id == id }).first
        if let existing {
            existing.deliveryStatusRaw = message.deliveryStatus.rawValue
        } else {
            context.insert(StoredMessage(from: message))
        }
        try context.save()
    }

    func updateDeliveryStatus(_ status: ChatMessage.DeliveryStatus, messageId: String) throws {
        let existing = try fetch(StoredMessage.self, where: #Predicate { $0.id == messageId }).first
        existing?.deliveryStatusRaw = status.rawValue
        try context.save()
    }

    /// Returns messages for a conversation sorted oldest → newest, capped at `limit`.
    func messages(for conversationId: String, limit: Int = 200) throws -> [ChatMessage] {
        var descriptor = FetchDescriptor<StoredMessage>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map { $0.toChatMessage() }
    }

    // MARK: - Conversations

    func save(_ conversation: Conversation) throws {
        let id = conversation.id
        let existing = try fetch(StoredConversation.self, where: #Predicate { $0.id == id }).first
        if let existing {
            existing.isPinned  = conversation.isPinned
            existing.isMuted   = conversation.isMuted
            existing.lastMessageTimestamp = conversation.lastMessage?.timestamp
        } else {
            context.insert(StoredConversation(from: conversation))
        }
        try context.save()
    }

    /// Returns all conversations sorted by last message time (newest first).
    func allConversations() throws -> [Conversation] {
        let descriptor = FetchDescriptor<StoredConversation>(
            sortBy: [SortDescriptor(\.lastMessageTimestamp, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap { $0.toConversation() }
    }

    // MARK: - Contacts

    func save(_ contact: Contact) throws {
        let pubkey = contact.pubkeyHex
        let existing = try fetch(StoredContact.self, where: #Predicate { $0.pubkeyHex == pubkey }).first
        if let existing {
            existing.displayName     = contact.displayName
            existing.about           = contact.about
            existing.pictureURLString = contact.pictureURL?.absoluteString
            existing.nip05           = contact.nip05
            existing.lastSeen        = contact.lastSeen
        } else {
            context.insert(StoredContact(from: contact))
        }
        try context.save()
    }

    func allContacts() throws -> [Contact] {
        try context.fetch(FetchDescriptor<StoredContact>()).map { $0.toContact() }
    }

    // MARK: - Private helper

    private func fetch<T: PersistentModel>(
        _ type: T.Type,
        where predicate: Predicate<T>? = nil
    ) throws -> [T] {
        let descriptor = FetchDescriptor<T>(predicate: predicate)
        return try context.fetch(descriptor)
    }
}
