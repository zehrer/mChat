import Foundation
import SwiftData
import mChatCore

/// SwiftData-backed implementation of `StorageBackend`.
/// All access happens on the `@MainActor` via the container's `mainContext`.
///
/// Registered into the plugin container by `SwiftDataStoragePlugin`.
/// Swap it out by registering a different `StorageBackend` implementation — no other
/// code needs to change.
@MainActor
final class MessageStore: StorageBackend {

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
            // Schema incompatibility — add a migration plan before shipping v2.
            fatalError("SwiftData container failed to initialise: \(error)")
        }
    }

    // MARK: - StorageBackend: Messages

    func save(_ message: ChatMessage) async throws {
        let id = message.id
        let existing = try fetch(StoredMessage.self, where: #Predicate { $0.id == id }).first
        if let existing {
            existing.deliveryStatusRaw = message.deliveryStatus.rawValue
        } else {
            context.insert(StoredMessage(from: message))
        }
        try context.save()
    }

    func updateDeliveryStatus(_ status: ChatMessage.DeliveryStatus, messageId: String) async throws {
        let existing = try fetch(StoredMessage.self, where: #Predicate { $0.id == messageId }).first
        existing?.deliveryStatusRaw = status.rawValue
        try context.save()
    }

    func messages(for conversationId: String, limit: Int = 200) async throws -> [ChatMessage] {
        var descriptor = FetchDescriptor<StoredMessage>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map { $0.toChatMessage() }
    }

    // MARK: - StorageBackend: Conversations

    func save(_ conversation: Conversation) async throws {
        let id = conversation.id
        let existing = try fetch(StoredConversation.self, where: #Predicate { $0.id == id }).first
        if let existing {
            existing.isPinned             = conversation.isPinned
            existing.isMuted              = conversation.isMuted
            existing.lastMessageTimestamp = conversation.lastMessage?.timestamp
        } else {
            context.insert(StoredConversation(from: conversation))
        }
        try context.save()
    }

    func allConversations() async throws -> [Conversation] {
        let descriptor = FetchDescriptor<StoredConversation>(
            sortBy: [SortDescriptor(\.lastMessageTimestamp, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap { $0.toConversation() }
    }

    // MARK: - StorageBackend: Contacts

    func save(_ contact: Contact) async throws {
        let pubkey = contact.pubkeyHex
        let existing = try fetch(StoredContact.self, where: #Predicate { $0.pubkeyHex == pubkey }).first
        if let existing {
            existing.displayName      = contact.displayName
            existing.about            = contact.about
            existing.pictureURLString = contact.pictureURL?.absoluteString
            existing.nip05            = contact.nip05
            existing.lastSeen         = contact.lastSeen
        } else {
            context.insert(StoredContact(from: contact))
        }
        try context.save()
    }

    func allContacts() async throws -> [Contact] {
        try context.fetch(FetchDescriptor<StoredContact>()).map { $0.toContact() }
    }

    // MARK: - Private

    private func fetch<T: PersistentModel>(
        _ type: T.Type,
        where predicate: Predicate<T>? = nil
    ) throws -> [T] {
        try context.fetch(FetchDescriptor<T>(predicate: predicate))
    }
}
