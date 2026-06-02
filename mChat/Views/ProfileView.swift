import SwiftUI
import mChatCore

struct ProfileView: View {
    @EnvironmentObject var identity: IdentityService
    @State private var editingName = ""
    @State private var editingAbout = ""
    @State private var isEditing = false
    @State private var showPrivateKey = false
    @State private var showDeleteConfirm = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                // Avatar + name
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            if let name = identity.profile?.name {
                                AvatarView(name: name, isGroup: false)
                                    .frame(width: 80, height: 80)
                            } else {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 80))
                                    .foregroundStyle(.secondary)
                            }
                            if let name = identity.profile?.displayName {
                                Text(name).font(.title3.bold())
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                // Profile fields
                Section("Profile") {
                    if isEditing {
                        TextField("Display name", text: $editingName)
                        TextField("About", text: $editingAbout, axis: .vertical)
                            .lineLimit(3...6)
                    } else {
                        LabeledContent("Name") {
                            Text(identity.profile?.displayName ?? "Not set")
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("About") {
                            Text(identity.profile?.about ?? "Not set")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Keys
                Section("Nostr Identity") {
                    LabeledContent("Public Key") {
                        HStack {
                            Text(identity.keyPair?.publicKeyHex.prefix(16).appending("…") ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = identity.keyPair?.publicKeyHex
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        showPrivateKey = true
                    } label: {
                        Label("Show Private Key", systemImage: "key.fill")
                    }
                }

                // Danger zone
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Identity", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveProfile() }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isEditing = false }
                    }
                } else {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { startEditing() }
                    }
                }
            }
            .sheet(isPresented: $showPrivateKey) {
                PrivateKeySheet()
            }
            .confirmationDialog("Delete Identity", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { identity.deleteIdentity() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete your private key from this device. Back it up first.")
            }
        }
    }

    private func startEditing() {
        editingName  = identity.profile?.displayName ?? ""
        editingAbout = identity.profile?.about ?? ""
        isEditing = true
    }

    private func saveProfile() {
        guard let kp = identity.keyPair else { return }
        var contact = Contact(pubkeyHex: kp.publicKeyHex)
        contact.displayName = editingName.isEmpty ? nil : editingName
        contact.about       = editingAbout.isEmpty ? nil : editingAbout
        identity.updateProfile(contact)
        isEditing = false
    }
}

// MARK: - Private key export sheet

private struct PrivateKeySheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var identity: IdentityService
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)

                Text("Keep this private!")
                    .font(.title2.bold())

                Text("Anyone with this key can read your messages and impersonate you. Never share it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if revealed, let hex = identity.keyPair?.privateKeyHex {
                    Text(hex)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                        .onTapGesture {
                            UIPasteboard.general.string = hex
                        }
                    Text("Tap to copy")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button("Reveal Private Key") {
                        revealed = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Private Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
