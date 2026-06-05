import SwiftUI
import mChatCore

struct OnboardingView: View {
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var chat: ChatService

    @State private var showImport = false
    @State private var importKey = ""
    @State private var errorMessage: String?
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Logo / branding
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 72))
                        .foregroundStyle(.blue)
                    Text("mChat")
                        .font(.largeTitle.bold())
                    Text("Private, open, peer-to-peer messaging.\nNo phone number. No central server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                // Onboarding actions
                VStack(spacing: 16) {
                    Button(action: createIdentity) {
                        Label("Create New Identity", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isCreating)

                    Button("Import Existing Key") {
                        showImport = true
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 32)

                // Privacy statement
                Text("Your private key never leaves this device.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 32)
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showImport) {
                ImportKeyView()
            }
        }
    }

    private func createIdentity() {
        isCreating = true
        do {
            try identity.createNewIdentity()
            Task { await chat.start() }
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }
}

// MARK: - Import key sheet

private struct ImportKeyView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var identity: IdentityService
    @EnvironmentObject var chat: ChatService

    @State private var keyHex = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Private key (hex or nsec)", text: $keyHex)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Paste your 64-character hex private key")
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .disabled(keyHex.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func importKey() {
        do {
            try identity.importIdentity(privateKeyHex: keyHex.trimmingCharacters(in: .whitespaces))
            Task { await chat.start() }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
