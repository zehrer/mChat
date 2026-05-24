import Foundation
import SwiftUI
import AppBrickCore
import mChatCore

/// Orchestrates all registered messaging and storage backends.
///
/// `ChatService` is the composition root's consumer — it never instantiates
/// backends itself. Instead it resolves them from the `AppEnvironment` that was
/// assembled in `mChatApp` by wiring `AppPlugin` conformances.
///
/// Adding a new protocol backend (Matrix, XMPP, …):
///   1. Create `MatrixPlugin` conforming to `AppPlugin`
///   2. Register it in `mChatApp` → `PluginContainer`
///   3. `ChatService.start()` picks it up automatically — no changes here.
///
/// Adding a new storage backend (iCloud, SQLite, GraphDB, …):
///   1. Create a type conforming to `StorageBackend`
///   2. Create a plugin that registers it as `StorageBackendBox`
///   3. Swap the plugin in `mChatApp` → done.
@MainActor
public final class ChatService: ObservableObject {

    @Published public private(set) var conversations: [Conversation] = []
    @Published public private(set) var messages: [String: [ChatMessage]] = [:]
    @Published public private(set) var contacts:  [String: Contact] = [:]
    @Published public var isConnected = false

    private let env: AppEnvironment
    private let identity = IdentityService.shared
    private var incomingTasks: [ChatProtocol: Task<Void, Never>] = [:]

    private var storage: any StorageBackend {
        env.plugins.require(StorageBackendBox.self).backend
    }

    public init(environment: AppEnvironment) {
        self.env = environment
    }

    // MARK: - Lifecycle

    public func start() async {
        await loadPersistedState()
        guard identity.keyPair != nil else { return }

        // Connect every registered MessagingBackend.
        // New protocols appear here automatically once their plugin is registered.
        for proto in ChatProtocol.allCases {
            switch proto {
            case .nostr:
                guard let backend = env.plugins.resolve(NostrBackend.self) else { continue }
                BackendRegistry.shared.register(backend)
                do {
                    try await backend.connect()
                    isConnected = true
                } catch {
                    env.logger.error("[ChatService] \(proto.rawValue) connect failed: \(error)")
                }
                listenForIncoming(backend: backend)
            default:
                break  // Matrix, XMPP etc. resolved here in Phase 3
            }
        }
    }

    public func stop() async {
        incomingTasks.values.forEach { $0.cancel() }
        incomingTasks = [:]
        isConnected = false
    }

    // MARK: - Conversations

    public func openConversation(with peerIdentifier: String, protocol proto: ChatProtocol = .nostr) -> Conversation {
        let conv = Conversation(protocol: proto, type: .oneToOne(peerIdentifier: peerIdentifier))
        if !conversations.contains(conv) {
            conversations.insert(conv, at: 0)
            Task { try? await storage.save(conv) }
        }
        if messages[conv.id] == nil {
            Task {
                messages[conv.id] = (try? await storage.messages(for: conv.id)) ?? []
            }
        }
        return conv
    }

    public func createGroup(name: String, members: [String], protocol proto: ChatProtocol = .nostr) async throws -> Conversation {
        guard let backend = BackendRegistry.shared.backend(for: proto) else {
            throw ChatServiceError.backendNotAvailable(proto)
        }
        let conv = try await backend.createGroup(name: name, members: members)
        if !conversations.contains(conv) {
            conversations.insert(conv, at: 0)
            try? await storage.save(conv)
        }
        return conv
    }

    // MARK: - Sending

    public func send(text: String, in conversation: Conversation) async throws {
        guard let backend = BackendRegistry.shared.backend(for: conversation.protocol) else {
            throw ChatServiceError.backendNotAvailable(conversation.protocol)
        }
        var msg = try await backend.send(text: text, in: conversation)
        msg = ChatMessage(
            id: msg.id,
            conversationId: msg.conversationId,
            senderIdentifier: msg.senderIdentifier,
            content: msg.content,
            timestamp: msg.timestamp,
            fromMe: msg.fromMe,
            deliveryStatus: .sending,
            protocol: msg.protocol
        )
        append(message: msg)
        try? await storage.save(msg)
        await updateConversationLastMessage(msg)
    }

    // MARK: - Contact resolution

    public func resolveContact(identifier: String, protocol proto: ChatProtocol = .nostr) async {
        guard contacts[identifier] == nil,
              let backend = BackendRegistry.shared.backend(for: proto) else { return }
        if let c = try? await backend.resolveContact(identifier: identifier) {
            contacts[identifier] = c
            try? await storage.save(c)
        }
    }

    // MARK: - Private: bootstrap from storage

    private func loadPersistedState() async {
        conversations = (try? await storage.allConversations()) ?? []

        let storedContacts = (try? await storage.allContacts()) ?? []
        for contact in storedContacts { contacts[contact.pubkeyHex] = contact }

        for conv in conversations {
            let msgs = (try? await storage.messages(for: conv.id)) ?? []
            guard !msgs.isEmpty else { continue }
            messages[conv.id] = msgs
            if let last = msgs.last, let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
                conversations[idx].lastMessage = last
            }
        }
    }

    // MARK: - Private: incoming messages

    private func listenForIncoming(backend: some MessagingBackend) {
        let proto = backend.chatProtocol
        let task = Task { [weak self] in
            let stream = await backend.incomingMessages()
            for await message in stream {
                await MainActor.run { self?.handleIncoming(message) }
            }
        }
        incomingTasks[proto] = task
    }

    private func handleIncoming(_ message: ChatMessage) {
        let conv = Conversation(
            protocol: message.protocol,
            type: .oneToOne(peerIdentifier: message.senderIdentifier)
        )
        if !conversations.contains(conv) {
            conversations.insert(conv, at: 0)
            Task { try? await storage.save(conv) }
        }
        append(message: message)
        Task { try? await storage.save(message) }
        Task { await updateConversationLastMessage(message) }
        Task { await resolveContact(identifier: message.senderIdentifier, protocol: message.protocol) }
    }

    // MARK: - Private: in-memory helpers

    private func append(message: ChatMessage) {
        var list = messages[message.conversationId] ?? []
        guard !list.contains(where: { $0.id == message.id }) else { return }
        list.append(message)
        list.sort { $0.timestamp < $1.timestamp }
        messages[message.conversationId] = list
    }

    private func updateConversationLastMessage(_ msg: ChatMessage) async {
        guard let idx = conversations.firstIndex(where: { $0.id == msg.conversationId }) else { return }
        conversations[idx].lastMessage = msg
        try? await storage.save(conversations[idx])
    }
}

// MARK: - Errors

public enum ChatServiceError: LocalizedError {
    case backendNotAvailable(ChatProtocol)

    public var errorDescription: String? {
        switch self {
        case .backendNotAvailable(let p):
            return "\(p.rawValue) backend is not connected"
        }
    }
}
