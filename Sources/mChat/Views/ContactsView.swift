import SwiftUI
import mChatCore

struct ContactsView: View {
    @EnvironmentObject var chat: ChatService
    @State private var searchText = ""

    private var contacts: [Contact] {
        let all = Array(chat.contacts.values).sorted { $0.name < $1.name }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if chat.contacts.isEmpty {
                    ContentUnavailableView(
                        "No Contacts",
                        systemImage: "person.2",
                        description: Text("Contacts appear here after you start a conversation")
                    )
                } else {
                    List(contacts) { contact in
                        NavigationLink {
                            ContactDetailView(contact: contact)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: contact.name, isGroup: false)
                                    .frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name).font(.headline)
                                    if let nip05 = contact.nip05 {
                                        Label(nip05, systemImage: "checkmark.seal.fill")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else if let about = contact.about {
                                        Text(about)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText)
                }
            }
            .navigationTitle("Contacts")
        }
    }
}

// MARK: - Contact detail

private struct ContactDetailView: View {
    let contact: Contact
    @EnvironmentObject var chat: ChatService
    @State private var navigateToChat = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        AvatarView(name: contact.name, isGroup: false)
                            .frame(width: 72, height: 72)
                        Text(contact.name).font(.title2.bold())
                        if let nip05 = contact.nip05 {
                            Label(nip05, systemImage: "checkmark.seal.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Button(action: openChat) {
                    Label("Send Message", systemImage: "bubble.left")
                }
            }

            if let about = contact.about {
                Section("About") {
                    Text(about).foregroundStyle(.secondary)
                }
            }

            Section("Public Key") {
                Text(contact.pubkeyHex)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToChat) {
            let conv = chat.openConversation(with: contact.pubkeyHex)
            ChatView(conversation: conv)
        }
    }

    private func openChat() {
        _ = chat.openConversation(with: contact.pubkeyHex)
        navigateToChat = true
    }
}
