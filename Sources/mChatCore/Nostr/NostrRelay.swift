import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Relay message types

public enum RelayMessage: Sendable {
    case event(subscriptionId: String, event: NostrEvent)
    case endOfStoredEvents(subscriptionId: String)
    case notice(String)
    case ok(eventId: String, accepted: Bool, message: String)
    case closed(subscriptionId: String, message: String)
    case connectionError(Error)
}

// MARK: - NostrRelay

/// Manages a single WebSocket connection to one Nostr relay.
/// All mutable state is protected by the actor.
public actor NostrRelay {

    public let url: URL

    public enum State: Sendable {
        case disconnected, connecting, connected, failed(Error)
    }
    public private(set) var state: State = .disconnected

    private var task: URLSessionWebSocketTask?
    private var messageContinuation: AsyncStream<RelayMessage>.Continuation?
    public let messages: AsyncStream<RelayMessage>

    private var activeSubscriptions: [String: NostrFilter] = [:]
    private var connectContinuation: CheckedContinuation<Void, Never>?

    public init(url: URL) {
        self.url = url
        var cont: AsyncStream<RelayMessage>.Continuation?
        messages = AsyncStream(RelayMessage.self, bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        messageContinuation = cont
    }

    // MARK: - Connection lifecycle

    public func connect() async {
        guard case .disconnected = state else { return }
        state = .connecting
        let session = URLSession(configuration: .default)
        let wst = session.webSocketTask(with: url)
        task = wst
        wst.resume()

        // Wait until the receive loop signals the WebSocket is open before sending subscriptions
        await withCheckedContinuation { cont in
            connectContinuation = cont
            Task { await self.receiveLoop() }
        }

        for (id, filter) in activeSubscriptions {
            try? await sendSubscribe(id: id, filter: filter)
        }
    }

    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    // MARK: - Subscriptions

    public func subscribe(id: String, filter: NostrFilter) async throws {
        activeSubscriptions[id] = filter
        try await sendSubscribe(id: id, filter: filter)
    }

    public func unsubscribe(id: String) async throws {
        activeSubscriptions.removeValue(forKey: id)
        try await sendRaw("[\"CLOSE\",\"\(id)\"]")
    }

    // MARK: - Publishing

    public func publish(event: NostrEvent) async throws {
        let eventJSON = try JSONEncoder().encode(event)
        guard let eventStr = String(data: eventJSON, encoding: .utf8) else { return }
        try await sendRaw("[\"EVENT\",\(eventStr)]")
    }

    // MARK: - Private helpers

    private func sendSubscribe(id: String, filter: NostrFilter) async throws {
        let filterJSON = try JSONEncoder().encode(filter)
        guard let filterStr = String(data: filterJSON, encoding: .utf8) else { return }
        #if DEBUG
        print("[relay REQ] \(url.host ?? "") sub:\(id.prefix(8)) filter:\(filterStr)")
        #endif
        try await sendRaw("[\"REQ\",\"\(id)\",\(filterStr)]")
    }

    private func sendRaw(_ text: String) async throws {
        guard let wst = task, case .connected = state else {
            throw NostrError.relayNotConnected
        }
        try await wst.send(.string(text))
    }

    private func receiveLoop() async {
        guard let wst = task else {
            connectContinuation?.resume()
            connectContinuation = nil
            return
        }
        // Signal connect() that the socket is open and ready for subscriptions
        state = .connected
        connectContinuation?.resume()
        connectContinuation = nil

        while true {
            do {
                let msg = try await wst.receive()
                switch msg {
                case .string(let text): handleIncoming(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handleIncoming(text) }
                @unknown default: break
                }
            } catch {
                state = .failed(error)
                messageContinuation?.yield(.connectionError(error))
                return
            }
        }
    }

    private func handleIncoming(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let arr  = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let type = arr.first as? String
        else { return }

        switch type {
        case "EVENT":
            guard arr.count >= 3,
                  let eventData = try? JSONSerialization.data(withJSONObject: arr[2]),
                  let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData)
            else { return }
            let subId = arr[1] as? String ?? ""
            messageContinuation?.yield(.event(subscriptionId: subId, event: event))

        case "EOSE":
            let subId = arr[1] as? String ?? ""
            messageContinuation?.yield(.endOfStoredEvents(subscriptionId: subId))

        case "NOTICE":
            let notice = arr[1] as? String ?? ""
            messageContinuation?.yield(.notice(notice))

        case "OK":
            let eventId  = arr[1] as? String ?? ""
            let accepted = arr[2] as? Bool ?? false
            let message  = arr[3] as? String ?? ""
            messageContinuation?.yield(.ok(eventId: eventId, accepted: accepted, message: message))

        case "CLOSED":
            let subId   = arr[1] as? String ?? ""
            let message = arr[2] as? String ?? ""
            messageContinuation?.yield(.closed(subscriptionId: subId, message: message))

        default: break
        }
    }
}
