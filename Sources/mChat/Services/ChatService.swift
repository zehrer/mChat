import Foundation
import SwiftUI
import mChatCore

/// The app-level service that orchestrates multiple backends and owns
/// the in-memory state that drives the UI.
/// SwiftData persistence is handled transparently via MessageStore.
@MainActor
public final class ChatService: ObservableObject {

    public static let shared = ChatService()

    @Published public private(set) var conversations: [Conversation] = []
    @Published public private(set) var messages: [String: [ChatMessage]] = [:]
    @Published public private(set) var contacts:  [String: Contact] = [:]
    @Published public var isConnected = false

    private let identity = IdentityService.shared
    private let store    = MessageStore.shared

    private var incomingTasks: [ChatProtocol: Task<Void, Never>] = [:]
    private var nostrBackend: NostrBackend?

    private init() {}

    // MARK: - Lifecycle

    public func start() async {
        loadPersistedState()

        guard let kp = identity.keyPair else { return }

        let nostr = NostrBackend(keyPair: kp)
        nostrBackend = nostr
        BackendRegistry.shared.register(nostr)

        do {
            try await nostr.connect()
            isConnected = true
        } catch {
            print("[ChatService] Nostr connect failed: \(error)")
        }

        listenForIncoming(backend: nostr)
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
            persistConversation(conv)
        }
        // Load any persisted messages for this conversation if not already in memory
        if messages[conv.id] == nil {
            messages[conv.id] = (try? store.messages(for: conv.id)) ?? []
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
            persistConversation(conv)
        }
        return conv
    }

    // MARK: - Sending

    public func send(text: String, in conversation: Conversation) async throws {
        guard let backend = BackendRegistry.shared.backend(for: conversation.protocol) else {
            throw ChatServiceError.backendNotAvailable(conversation.protocol)
        }
        var msg = try await backend.send(text: text, in: conversation)
        // Mark as sending until the relay confirms OK
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
        persistMessage(msg)
        updateConversationLastMessage(msg)
    }

    // MARK: - Contact resolution

    public func resolveContact(identifier: String, protocol proto: ChatProtocol = .nostr) async {
        guard contacts[identifier] == nil,
              let backend = BackendRegistry.shared.backend(for: proto) else { return }
        if let c = try? await backend.resolveContact(identifier: identifier) {
            contacts[identifier] = c
            try? store.save(c)
        }
    }

    // MARK: - Private: persistence

    private func loadPersistedState() {
        // Conversations
        let storedConvs = (try? store.allConversations()) ?? []
        conversations = storedConvs

        // Contacts
        let storedContacts = (try? store.allContacts()) ?? []
        for contact in storedContacts {
            contacts[contact.pubkeyHex] = contact
        }

        // Recent messages for each conversation
        for conv in conversations {
            let msgs = (try? store.messages(for: conv.id)) ?? []
            guard !msgs.isEmpty else { continue }
            messages[conv.id] = msgs
            if let last = msgs.last, let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
                conversations[idx].lastMessage = last
            }
        }
    }

    private func persistMessage(_ msg: ChatMessage) {
        try? store.save(msg)
    }

    private func persistConversation(_ conv: Conversation) {
        try? store.save(conv)
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
        let conv: Conversation
        switch message.protocol {
        default:
            conv = Conversation(
                protocol: message.protocol,
                type: .oneToOne(peerIdentifier: message.senderIdentifier)
            )
        }
        if !conversations.contains(conv) {
            conversations.insert(conv, at: 0)
            persistConversation(conv)
        }

        append(message: message)
        persistMessage(message)
        updateConversationLastMessage(message)

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

    private func updateConversationLastMessage(_ msg: ChatMessage) {
        guard let idx = conversations.firstIndex(where: { $0.id == msg.conversationId }) else { return }
        conversations[idx].lastMessage = msg
        persistConversation(conversations[idx])
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
