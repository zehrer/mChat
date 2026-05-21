import Foundation
import SwiftUI
import mChatCore

/// The app-level service that orchestrates multiple backends.
/// All UI should talk to ChatService rather than individual backends.
@MainActor
public final class ChatService: ObservableObject {

    public static let shared = ChatService()

    @Published public private(set) var conversations: [Conversation] = []
    @Published public private(set) var messages: [String: [ChatMessage]] = [:]  // conversationId → messages
    @Published public private(set) var contacts:  [String: Contact] = [:]
    @Published public var isConnected = false

    private let identity = IdentityService.shared
    private var incomingTasks: [ChatProtocol: Task<Void, Never>] = [:]
    private var nostrBackend: NostrBackend?

    private init() {}

    // MARK: - Lifecycle

    public func start() async {
        guard let kp = identity.keyPair else { return }

        // Nostr backend (always active)
        let nostr = NostrBackend(keyPair: kp)
        nostrBackend = nostr
        BackendRegistry.shared.register(nostr)
        do {
            try await nostr.connect()
            isConnected = true
        } catch {
            print("[ChatService] Nostr connect failed: \(error)")
        }

        // Start listening for incoming messages from all backends
        listenForIncoming(backend: nostr)

        // Matrix, XMPP, etc. will be registered here in future phases:
        // let matrix = MatrixBackend(...)
        // BackendRegistry.shared.register(matrix)
        // listenForIncoming(backend: matrix)
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
        append(message: msg, to: conversation.id)
        updateConversationLastMessage(msg)
    }

    // MARK: - Contact resolution

    public func resolveContact(identifier: String, protocol proto: ChatProtocol = .nostr) async {
        guard contacts[identifier] == nil,
              let backend = BackendRegistry.shared.backend(for: proto) else { return }
        if let c = try? await backend.resolveContact(identifier: identifier) {
            contacts[identifier] = c
        }
    }

    // MARK: - Private

    private func listenForIncoming(backend: some MessagingBackend) {
        let proto = backend.chatProtocol
        let task = Task { [weak self] in
            let stream = await backend.incomingMessages()
            for await message in stream {
                await MainActor.run {
                    self?.handleIncoming(message)
                }
            }
        }
        incomingTasks[proto] = task
    }

    private func handleIncoming(_ message: ChatMessage) {
        // Ensure a conversation entry exists
        let conv: Conversation
        switch message.protocol {
        case .nostr:
            conv = Conversation(protocol: .nostr,
                                type: .oneToOne(peerIdentifier: message.senderIdentifier))
        default:
            conv = Conversation(protocol: message.protocol,
                                type: .oneToOne(peerIdentifier: message.senderIdentifier))
        }
        if !conversations.contains(conv) {
            conversations.insert(conv, at: 0)
        }
        append(message: message, to: conv.id)
        updateConversationLastMessage(message)

        // Kick off contact resolution in background
        Task { await resolveContact(identifier: message.senderIdentifier, protocol: message.protocol) }
    }

    private func append(message: ChatMessage, to conversationId: String) {
        var list = messages[conversationId] ?? []
        if !list.contains(where: { $0.id == message.id }) {
            list.append(message)
            list.sort { $0.timestamp < $1.timestamp }
            messages[conversationId] = list
        }
    }

    private func updateConversationLastMessage(_ msg: ChatMessage) {
        if let idx = conversations.firstIndex(where: { $0.id == msg.conversationId }) {
            var conv = conversations[idx]
            conv.lastMessage = msg
            conversations[idx] = conv
        }
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
