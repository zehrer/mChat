import Foundation

/// Nostr implementation of `MessagingBackend`.
///
/// Supported conversation types:
/// - `.oneToOne`  → NIP-17 sealed-sender DMs (kind 1059); also receives NIP-04 (kind 4)
/// - `.group`     → NIP-28 channel messages (kind 42)  [stubbed, Phase 2]
public actor NostrBackend: MessagingBackend {

    public nonisolated let chatProtocol: ChatProtocol = .nostr

    private let keyPair: NostrKeyPair
    private let client: NostrClient
    private var incomingContinuation: AsyncStream<ChatMessage>.Continuation?
    private let incomingStream: AsyncStream<ChatMessage>

    public init(keyPair: NostrKeyPair, relays: [URL] = NostrClient.defaultRelays) {
        self.keyPair = keyPair
        self.client = NostrClient()
        var cont: AsyncStream<ChatMessage>.Continuation?
        incomingStream = AsyncStream(ChatMessage.self, bufferingPolicy: .bufferingNewest(512)) {
            cont = $0
        }
        incomingContinuation = cont
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        for url in NostrClient.defaultRelays {
            await client.addRelay(url: url)
        }
        await subscribeToIncomingDMs()
        await subscribeToIncomingGiftWraps()
    }

    public func disconnect() async {
        incomingContinuation?.finish()
    }

    // MARK: - Messaging

    public func send(text: String, in conversation: Conversation) async throws -> ChatMessage {
        switch conversation.type {
        case .oneToOne(let peerPubkey):
            return try await sendDM(text: text, to: peerPubkey, conversationId: conversation.id)
        case .group(let channelId, _):
            return try await sendChannelMessage(text: text, channelId: channelId, conversationId: conversation.id)
        }
    }

    public func incomingMessages() -> AsyncStream<ChatMessage> {
        incomingStream
    }

    public func publishProfile(name: String, about: String?) async throws {
        let event = try NostrEvent.metadata(
            name: name, about: about, picture: nil, nip05: nil, keyPair: keyPair
        )
        await client.publish(event: event)
    }

    public func loadHistory(for conversation: Conversation, limit: Int) async throws -> [ChatMessage] {
        // History is fetched live from relays; a local SwiftData cache should be
        // the primary source in the app layer (see MessageStore).
        return []
    }

    // MARK: - Contacts

    public func resolveContact(identifier: String) async throws -> Contact {
        var resolved: Contact? = nil
        let filter = NostrFilter.metadata(for: [identifier])
        let subId = await client.subscribe(filter: filter) { event in
            if let contact = Contact.from(metadataEvent: event) {
                resolved = contact
            }
        }
        // Give relays 3 seconds to respond
        try await Task.sleep(for: .seconds(3))
        await client.unsubscribe(id: subId)
        return resolved ?? Contact(pubkeyHex: identifier)
    }

    // MARK: - Group chats (NIP-28 stub)

    public func createGroup(name: String, members: [String]) async throws -> Conversation {
        // NIP-28: kind 40 creates a channel.
        // Full NIP-28 implementation is Phase 2.
        let channelId = UUID().uuidString
        return Conversation(
            protocol: .nostr,
            type: .group(groupIdentifier: channelId, name: name)
        )
    }

    public func addMember(_ identifier: String, to conversation: Conversation) async throws {
        // NIP-28 channel invite — Phase 2
    }

    public func removeMember(_ identifier: String, from conversation: Conversation) async throws {
        // Nostr has no native kick; can only revoke relay access — Phase 2
    }

    // MARK: - Private helpers

    private func sendDM(text: String, to peerPubkey: String, conversationId: String) async throws -> ChatMessage {
        let event = try NostrEvent.giftWrap(
            content: text,
            recipientPubkey: peerPubkey,
            keyPair: keyPair
        )
        await client.publish(event: event)
        return ChatMessage(
            id: event.id,
            conversationId: conversationId,
            senderIdentifier: keyPair.publicKeyHex,
            content: text,
            timestamp: Date(),
            fromMe: true,
            deliveryStatus: .sending,
            protocol: .nostr
        )
    }

    private func sendChannelMessage(text: String, channelId: String, conversationId: String) async throws -> ChatMessage {
        // Kind 42 — NIP-28 channel message
        let event = try NostrEvent.build(
            kind: 42,
            tags: [["e", channelId, "", "root"]],
            content: text,
            keyPair: keyPair
        )
        await client.publish(event: event)
        return ChatMessage(
            id: event.id,
            conversationId: conversationId,
            senderIdentifier: keyPair.publicKeyHex,
            content: text,
            timestamp: event.date,
            fromMe: true,
            deliveryStatus: .sending,
            protocol: .nostr
        )
    }

    private func subscribeToIncomingDMs() async {
        let myPubkey = keyPair.publicKeyHex
        let privkeyBytes = keyPair.privateKeyBytes
        let since = Int(Date().timeIntervalSince1970)
        let filter = NostrFilter.incomingDMs(for: myPubkey, since: since)

        await client.subscribe(filter: filter) { [weak self] event in
            guard let self else { return }
            guard let msg = try? ChatMessage.fromNostrDM(
                event: event,
                myPubkeyHex: myPubkey,
                myPrivkeyBytes: privkeyBytes
            ) else { return }
            await self.yield(msg)
        }
    }

    private func subscribeToIncomingGiftWraps() async {
        let myPubkey = keyPair.publicKeyHex
        let privkeyBytes = keyPair.privateKeyBytes
        let since = Int(Date().timeIntervalSince1970)
        let filter = NostrFilter.incomingGiftWraps(for: myPubkey, since: since)

        await client.subscribe(filter: filter) { [weak self] event in
            guard let self else { return }
            guard let msg = try? ChatMessage.fromNostrGiftWrap(
                event: event,
                myPubkeyHex: myPubkey,
                myPrivkeyBytes: privkeyBytes
            ) else { return }
            await self.yield(msg)
        }
    }

    private func yield(_ message: ChatMessage) {
        incomingContinuation?.yield(message)
    }
}
