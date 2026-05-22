import SwiftUI
import mChatCore

struct ConversationListView: View {
    @EnvironmentObject var chat: ChatService
    @State private var searchText = ""
    @State private var showNewChat = false
    @State private var showNewGroup = false

    var filtered: [Conversation] {
        guard !searchText.isEmpty else { return chat.conversations }
        return chat.conversations.filter { conv in
            displayName(for: conv).localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if chat.conversations.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Tap + to start a chat")
                    )
                } else {
                    List(filtered) { conversation in
                        NavigationLink(value: conversation) {
                            ConversationRow(
                                conversation: conversation,
                                name: displayName(for: conversation)
                            )
                        }
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .searchable(text: $searchText, prompt: "Search")
                }
            }
            .navigationTitle("mChat")
            .navigationDestination(for: Conversation.self) { conv in
                ChatView(conversation: conv)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: { showNewChat = true }) {
                            Label("New Chat", systemImage: "person")
                        }
                        Button(action: { showNewGroup = true }) {
                            Label("New Group", systemImage: "person.3")
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView()
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView()
            }
        }
    }

    private func displayName(for conversation: Conversation) -> String {
        switch conversation.type {
        case .oneToOne(let peer):
            return chat.contacts[peer]?.name ?? conversation.displayName
        case .group(_, let name):
            return name
        }
    }
}

// MARK: - Conversation row

private struct ConversationRow: View {
    let conversation: Conversation
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: name, isGroup: conversation.isGroup)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name)
                        .font(.headline)
                    Spacer()
                    if let last = conversation.lastMessage {
                        Text(last.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    if let last = conversation.lastMessage {
                        Text(last.fromMe ? "You: \(last.content)" : last.content)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Avatar

struct AvatarView: View {
    let name: String
    let isGroup: Bool

    private var initial: String {
        String(name.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hue: Double(abs(name.hashValue) % 360) / 360, saturation: 0.5, brightness: 0.8))
                .frame(width: 48, height: 48)
            if isGroup {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            } else {
                Text(initial)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - New chat sheet

private struct NewChatView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chat: ChatService
    @State private var pubkeyInput = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nostr pubkey (hex)", text: $pubkeyInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Enter the recipient's public key")
                } footer: {
                    Text("Paste a 64-character hex pubkey or npub")
                }

                if let error = errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { openChat() }
                        .disabled(pubkeyInput.trimmingCharacters(in: .whitespaces).count < 64)
                }
            }
        }
    }

    private func openChat() {
        let key = pubkeyInput.trimmingCharacters(in: .whitespaces)
        _ = chat.openConversation(with: key)
        Task { await chat.resolveContact(identifier: key) }
        dismiss()
    }
}

// MARK: - New group sheet

private struct NewGroupView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var chat: ChatService
    @State private var groupName = ""
    @State private var memberKey = ""
    @State private var members: [String] = []
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("My group", text: $groupName)
                }

                Section("Members") {
                    ForEach(members, id: \.self) { m in
                        Text(String(m.prefix(16)) + "…")
                            .font(.system(.body, design: .monospaced))
                    }
                    .onDelete { members.remove(atOffsets: $0) }

                    HStack {
                        TextField("Add pubkey…", text: $memberKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.caption, design: .monospaced))
                        Button("Add") {
                            let k = memberKey.trimmingCharacters(in: .whitespaces)
                            if k.count == 64 { members.append(k); memberKey = "" }
                        }
                        .disabled(memberKey.trimmingCharacters(in: .whitespaces).count < 64)
                    }
                }

                if let error = errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isCreating)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createGroup() }
                        .disabled(groupName.isEmpty)
                }
            }
        }
    }

    private func createGroup() {
        isCreating = true
        Task {
            do {
                _ = try await chat.createGroup(name: groupName, members: members)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
