import Foundation

// MARK: - MessagingBackend protocol

/// The single abstraction that every chat protocol backend must implement.
///
/// To add a new protocol (Matrix, Telegram, XMPP, …):
/// 1. Create a new type conforming to `MessagingBackend`
/// 2. Register it in `BackendRegistry`
/// 3. Add the protocol case to `ChatProtocol`
///
/// The app layer (`ChatService`) only talks to this protocol,
/// so UI and storage code never need to know which wire protocol is in use.
public protocol MessagingBackend: Actor {

    /// The protocol this backend implements.
    var chatProtocol: ChatProtocol { get }

    // MARK: - Lifecycle

    func connect() async throws
    func disconnect() async

    // MARK: - Messaging

    /// Sends a plaintext message in a conversation.
    func send(text: String, in conversation: Conversation) async throws -> ChatMessage

    /// Streams incoming messages. Yields each new message as it arrives.
    /// The caller is responsible for cancelling the task when done.
    func incomingMessages() -> AsyncStream<ChatMessage>

    // MARK: - History

    /// Loads historical messages for a conversation (newest last).
    func loadHistory(for conversation: Conversation, limit: Int) async throws -> [ChatMessage]

    // MARK: - Contacts

    /// Resolves display metadata for a remote identity (best-effort).
    func resolveContact(identifier: String) async throws -> Contact

    // MARK: - Group chats

    /// Creates a new group conversation. Returns the created Conversation.
    func createGroup(name: String, members: [String]) async throws -> Conversation

    /// Adds a member to an existing group.
    func addMember(_ identifier: String, to conversation: Conversation) async throws

    /// Removes a member from an existing group.
    func removeMember(_ identifier: String, from conversation: Conversation) async throws
}

// MARK: - BackendRegistry

/// Central registry that maps ChatProtocol values to their backends.
/// The app keeps one shared instance and routes messages to the right backend.
public final class BackendRegistry: @unchecked Sendable {

    public static let shared = BackendRegistry()
    private init() {}

    private var backends: [ChatProtocol: any MessagingBackend] = [:]
    private let lock = NSLock()

    public func register(_ backend: some MessagingBackend) {
        lock.withLock { backends[backend.chatProtocol] = backend }
    }

    public func backend(for protocol: ChatProtocol) -> (any MessagingBackend)? {
        lock.withLock { backends[`protocol`] }
    }

    public var activeProtocols: [ChatProtocol] {
        lock.withLock { Array(backends.keys) }
    }
}
