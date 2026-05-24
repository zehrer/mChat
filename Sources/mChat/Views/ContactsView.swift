import SwiftUI
import Contacts

struct ContactsView: View {
    @EnvironmentObject var chat: ChatService
    @StateObject private var addressBook = ContactsIntegrationService.shared
    @State private var searchText = ""
    @State private var showLinkSheet = false

    // Nostr contacts resolved from relay metadata
    private var nostrContacts: [Contact] {
        let all = Array(chat.contacts.values).sorted { $0.name < $1.name }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // Address book contacts that have a Nostr pubkey linked
    private var linkedContacts: [LinkedContact] {
        guard searchText.isEmpty else {
            return addressBook.linkedContacts.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }
        return addressBook.linkedContacts
    }

    private var isEmpty: Bool { nostrContacts.isEmpty && linkedContacts.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if isEmpty && !addressBook.isLoading {
                    emptyState
                } else {
                    contactList
                }
            }
            .navigationTitle("Contacts")
            .searchable(text: $searchText, prompt: "Search contacts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showLinkSheet = true } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showLinkSheet) {
                LinkContactSheet()
            }
            .task {
                if addressBook.permissionStatus == .authorized {
                    await addressBook.fetchLinkedContacts()
                }
            }
        }
    }

    // MARK: - Subviews

    private var contactList: some View {
        List {
            // Address book contacts with linked Nostr pubkeys
            if !linkedContacts.isEmpty {
                Section {
                    ForEach(linkedContacts) { linked in
                        NavigationLink {
                            LinkedContactDetailView(linked: linked)
                        } label: {
                            LinkedContactRow(linked: linked)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { try? await addressBook.unlink(contactId: linked.contactId) }
                            } label: {
                                Label("Unlink", systemImage: "link.badge.minus")
                            }
                        }
                    }
                } header: {
                    Label("From Address Book", systemImage: "person.crop.circle")
                }
            }

            // Nostr contacts resolved from relay metadata
            if !nostrContacts.isEmpty {
                Section {
                    ForEach(nostrContacts) { contact in
                        NavigationLink {
                            ContactDetailView(contact: contact)
                        } label: {
                            NostrContactRow(contact: contact)
                        }
                    }
                } header: {
                    Label("Nostr Contacts", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "No Contacts",
                systemImage: "person.2",
                description: Text("Link contacts from your address book or start a conversation to add Nostr contacts.")
            )

            if addressBook.permissionStatus != .authorized {
                Button("Connect Address Book") {
                    Task { await addressBook.requestPermission() }
                }
                .buttonStyle(.borderedProminent)

                Text("mChat never uploads your contacts to any server.\nOnly contacts you manually link are used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

// MARK: - Linked contact row

private struct LinkedContactRow: View {
    let linked: LinkedContact

    var body: some View {
        HStack(spacing: 12) {
            ContactThumbnail(image: linked.thumbnail, name: linked.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(linked.displayName).font(.headline)
                Text(linked.nostrPubkeyHex.prefix(16) + "…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
            }
        }
    }
}

// MARK: - Nostr contact row

private struct NostrContactRow: View {
    let contact: Contact

    var body: some View {
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

// MARK: - Contact thumbnail (address book photo or initial)

struct ContactThumbnail: View {
    let image: UIImage?
    let name: String

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                AvatarView(name: name, isGroup: false)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }
}

// MARK: - Linked contact detail

private struct LinkedContactDetailView: View {
    let linked: LinkedContact
    @EnvironmentObject var chat: ChatService
    @StateObject private var addressBook = ContactsIntegrationService.shared
    @State private var navigateToChat = false
    @State private var showUnlinkConfirm = false

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        ContactThumbnail(image: linked.thumbnail, name: linked.displayName)
                            .frame(width: 72, height: 72)
                        Text(linked.displayName).font(.title2.bold())
                        Label("Address Book", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    _ = chat.openConversation(with: linked.nostrPubkeyHex)
                    navigateToChat = true
                } label: {
                    Label("Send Message", systemImage: "bubble.left")
                }
            }

            Section("Nostr Public Key") {
                Text(linked.nostrPubkeyHex)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) { showUnlinkConfirm = true } label: {
                    Label("Unlink Nostr Key", systemImage: "link.badge.minus")
                }
            }
        }
        .navigationTitle(linked.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToChat) {
            ChatView(conversation: chat.openConversation(with: linked.nostrPubkeyHex))
        }
        .confirmationDialog("Unlink Nostr key from \(linked.displayName)?",
                            isPresented: $showUnlinkConfirm,
                            titleVisibility: .visible) {
            Button("Unlink", role: .destructive) {
                Task { try? await addressBook.unlink(contactId: linked.contactId) }
            }
        }
    }
}

// MARK: - Nostr contact detail (unchanged, relay-resolved contacts)

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
            ChatView(conversation: chat.openConversation(with: contact.pubkeyHex))
        }
    }

    private func openChat() {
        _ = chat.openConversation(with: contact.pubkeyHex)
        navigateToChat = true
    }
}

// MARK: - Link contact sheet

struct LinkContactSheet: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var addressBook = ContactsIntegrationService.shared
    @State private var addressBookEntries: [AddressBookEntry] = []
    @State private var selectedEntry: AddressBookEntry?
    @State private var pubkeyInput = ""
    @State private var searchText = ""
    @State private var isLinking = false
    @State private var errorMessage: String?

    private var filtered: [AddressBookEntry] {
        guard !searchText.isEmpty else { return addressBookEntries }
        return addressBookEntries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if addressBook.permissionStatus != .authorized {
                    permissionPrompt
                } else if selectedEntry == nil {
                    contactPicker
                } else {
                    pubkeyEntry
                }
            }
            .navigationTitle(selectedEntry == nil ? "Choose Contact" : "Enter Nostr Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if selectedEntry != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Back") { selectedEntry = nil }
                    }
                }
            }
        }
        .task {
            guard addressBook.permissionStatus == .authorized else { return }
            addressBookEntries = (try? addressBook.allContacts()) ?? []
        }
    }

    // MARK: Step 1 – permission prompt

    private var permissionPrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            Text("Access Address Book")
                .font(.title2.bold())
            Text("mChat needs read access to show your contacts.\n\nYour contacts are never uploaded to any server — Nostr pubkeys are stored locally in the iOS Contacts app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Allow Access") {
                Task { await addressBook.requestPermission() }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: Step 2 – pick a contact

    private var contactPicker: some View {
        List(filtered) { entry in
            Button {
                selectedEntry = entry
                pubkeyInput = ""
            } label: {
                HStack(spacing: 12) {
                    ContactThumbnail(image: entry.thumbnail, name: entry.displayName)
                    Text(entry.displayName)
                        .foregroundStyle(.primary)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search")
        .listStyle(.plain)
    }

    // MARK: Step 3 – enter pubkey

    private var pubkeyEntry: some View {
        Form {
            if let entry = selectedEntry {
                Section {
                    HStack(spacing: 12) {
                        ContactThumbnail(image: entry.thumbnail, name: entry.displayName)
                        Text(entry.displayName).font(.headline)
                    }
                }
            }

            Section {
                TextField("Nostr public key (64-char hex)", text: $pubkeyInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Paste the contact's Nostr public key")
            } footer: {
                Text("This is stored in the iOS Contacts app under Instant Messages → Nostr. It never leaves your device.")
            }

            if let error = errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section {
                Button(action: linkContact) {
                    if isLinking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Link").frame(maxWidth: .infinity)
                    }
                }
                .disabled(pubkeyInput.trimmingCharacters(in: .whitespaces).count != 64 || isLinking)
            }
        }
    }

    private func linkContact() {
        guard let entry = selectedEntry else { return }
        let key = pubkeyInput.trimmingCharacters(in: .whitespaces)
        isLinking = true
        Task {
            do {
                try await addressBook.link(pubkeyHex: key, to: entry.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isLinking = false
            }
        }
    }
}
