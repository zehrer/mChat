import Foundation

// MARK: - StorageBackend

/// Protocol that every storage implementation must satisfy.
///
/// Swap implementations without touching any other code:
/// - `SwiftDataStoragePlugin`  — local SwiftData (default)
/// - `iCloudStoragePlugin`     — CloudKit sync (Phase 2)
/// - `SQLiteStoragePlugin`     — embedded SQLite (Phase 3)
/// - `GraphDBStoragePlugin`    — custom graph database (Phase 3)
///
/// Register a conformance via an `AppPlugin` in the composition root (`mChatApp`).
public protocol StorageBackend: Sendable {

    // MARK: Messages
    func save(_ message: ChatMessage) async throws
    func updateDeliveryStatus(_ status: ChatMessage.DeliveryStatus, messageId: String) async throws
    func messages(for conversationId: String, limit: Int) async throws -> [ChatMessage]

    // MARK: Conversations
    func save(_ conversation: Conversation) async throws
    func allConversations() async throws -> [Conversation]

    // MARK: Contacts
    func save(_ contact: Contact) async throws
    func allContacts() async throws -> [Contact]
}

// MARK: - StorageBackendBox

/// Thin Sendable wrapper used to store `any StorageBackend` in `PluginContainer`,
/// which is keyed by concrete `ObjectIdentifier` and cannot store existentials directly.
public struct StorageBackendBox: Sendable {
    public let backend: any StorageBackend
    public init(_ backend: some StorageBackend) { self.backend = backend }
}
