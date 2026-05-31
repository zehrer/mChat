import Foundation

/// High-level Nostr client that manages multiple relay connections and
/// routes incoming events to subscribers.
public actor NostrClient {

    // MARK: - Public relay list (matches Stephan's NIP-17 DM relay list)
    public static let defaultRelays: [URL] = [
        URL(string: "wss://purplepag.es")!,
        URL(string: "wss://nostr.wine")!,
        URL(string: "wss://nos.lol")!,
    ]

    private var relays: [URL: NostrRelay] = [:]
    private var eventHandlers: [String: (NostrEvent) async -> Void] = [:]
    private var relayTasks: [URL: Task<Void, Never>] = [:]
    private var seenEventIds: Set<String> = []

    public init() {}

    // MARK: - Relay management

    public func addRelay(url: URL) async {
        guard relays[url] == nil else { return }
        let relay = NostrRelay(url: url)
        relays[url] = relay
        await relay.connect()
        let task = Task { [weak self] in
            guard let self else { return }
            for await message in await relay.messages {
                await self.handle(message, from: relay)
            }
        }
        relayTasks[url] = task
    }

    public func removeRelay(url: URL) async {
        relayTasks[url]?.cancel()
        relayTasks[url] = nil
        await relays[url]?.disconnect()
        relays[url] = nil
    }

    // MARK: - Subscriptions

    /// Subscribes on all connected relays. Returns a subscription ID you can use to cancel.
    @discardableResult
    public func subscribe(
        filter: NostrFilter,
        id: String? = nil,
        onEvent: @escaping (NostrEvent) async -> Void
    ) async -> String {
        let subId = id ?? UUID().uuidString
        eventHandlers[subId] = onEvent
        for relay in relays.values {
            try? await relay.subscribe(id: subId, filter: filter)
        }
        return subId
    }

    public func unsubscribe(id: String) async {
        eventHandlers.removeValue(forKey: id)
        for relay in relays.values {
            try? await relay.unsubscribe(id: id)
        }
    }

    // MARK: - Publishing

    /// Broadcasts an event to all connected relays.
    public func publish(event: NostrEvent) async {
        for (url, relay) in relays {
            do {
                try await relay.publish(event: event)
                #if DEBUG
                print("[relay] sent kind:\(event.kind) \(event.id.prefix(8))… → \(url.host ?? url.absoluteString)")
                #endif
            } catch {
                print("[relay] publish FAILED to \(url.host ?? url.absoluteString): \(error)")
            }
        }
    }

    // MARK: - Private

    private func handle(_ message: RelayMessage, from relay: NostrRelay) async {
        switch message {
        case .event(let subId, let event):
            #if DEBUG
            print("[relay EVENT] kind:\(event.kind) \(event.id.prefix(8))… sub:\(subId.prefix(8))")
            #endif
            if let handler = eventHandlers[subId] {
                guard seenEventIds.insert(event.id).inserted else { return }
                await handler(event)
            } else {
                #if DEBUG
                print("[relay EVENT] no handler for sub:\(subId.prefix(8)) — registered: \(eventHandlers.keys.map { $0.prefix(8) })")
                #endif
            }
        case .ok(let eventId, let accepted, let msg):
            #if DEBUG
            let status = accepted ? "✓" : "✗"
            print("[relay OK] \(status) \(eventId.prefix(8))… \(msg)")
            #endif
            _ = (eventId, accepted, msg)
        case .notice(let text):
            #if DEBUG
            print("[relay NOTICE] \(text)")
            #endif
            _ = text
        default:
            break
        }
    }
}
