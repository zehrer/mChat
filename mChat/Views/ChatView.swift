import SwiftUI
import mChatCore

struct ChatView: View {
    let conversation: Conversation

    @EnvironmentObject var chat: ChatService
    @EnvironmentObject var identity: IdentityService
    @State private var draftText = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool
    @Namespace private var bottomID

    private var messages: [ChatMessage] {
        chat.messages[conversation.id] ?? []
    }

    private var peerName: String {
        switch conversation.type {
        case .oneToOne(let peer):
            return chat.contacts[peer]?.name ?? String(peer.prefix(12)) + "…"
        case .group(_, let name):
            return name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onAppear {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }

            Divider()

            // Input bar
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message", text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .lineLimit(1...6)
                    .focused($inputFocused)

                Button(action: sendMessage) {
                    Image(systemName: draftText.isEmpty ? "mic" : "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(draftText.isEmpty ? .secondary : .blue)
                        .animation(.spring(), value: draftText.isEmpty)
                }
                .disabled(isSending || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
        }
        .navigationTitle(peerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(peerName).font(.headline)
                    Text(conversation.protocol.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("Failed to send", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            // Resolve contact info in background
            if case .oneToOne(let peer) = conversation.type {
                await chat.resolveContact(identifier: peer, protocol: conversation.protocol)
            }
        }
    }

    private func sendMessage() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draftText = ""
        isSending = true
        Task {
            do {
                try await chat.send(text: text, in: conversation)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 60) }

            VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.fromMe ? Color.blue : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .foregroundStyle(message.fromMe ? .white : .primary)

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if message.fromMe {
                        deliveryIcon
                    }
                }
            }

            if !message.fromMe { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var deliveryIcon: some View {
        switch message.deliveryStatus {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2).foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2).foregroundStyle(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2).foregroundStyle(.red)
        }
    }
}
