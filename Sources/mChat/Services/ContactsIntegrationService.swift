import Foundation
import Contacts
import UIKit
import mChatCore

// MARK: - LinkedContact

/// An iOS address book contact that has a Nostr pubkey stored in their
/// instant message addresses (service name: "Nostr").
public struct LinkedContact: Identifiable, Sendable {
    public let contactId: String        // CNContact.identifier
    public let nostrPubkeyHex: String   // 64-char hex
    public let displayName: String
    public let thumbnailData: Data?     // CNContact.thumbnailImageData

    public var id: String { contactId }

    public var thumbnail: UIImage? {
        thumbnailData.flatMap { UIImage(data: $0) }
    }
}

// MARK: - ContactsIntegrationService

/// Bridges the iOS Contacts framework with mChat's Nostr identity model.
///
/// Privacy guarantee: this service never uploads contact data to any server.
/// It only reads CNContacts that the user has already tagged with a Nostr
/// pubkey on-device. No phone-number-to-pubkey matching is performed.
@MainActor
public final class ContactsIntegrationService: ObservableObject {

    public static let shared = ContactsIntegrationService()

    @Published public private(set) var permissionStatus: CNAuthorizationStatus = .notDetermined
    @Published public private(set) var linkedContacts: [LinkedContact] = []
    @Published public private(set) var isLoading = false

    /// The CNInstantMessageAddress service name used to store Nostr pubkeys.
    static let nostrIMService = "Nostr"

    private let store = CNContactStore()

    private init() {
        permissionStatus = CNContactStore.authorizationStatus(for: .contacts)
    }

    // MARK: - Permission

    public func requestPermission() async -> Bool {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            permissionStatus = CNContactStore.authorizationStatus(for: .contacts)
            if granted { await fetchLinkedContacts() }
            return granted
        } catch {
            permissionStatus = .denied
            return false
        }
    }

    // MARK: - Fetch linked contacts

    /// Fetches all iOS contacts that have a Nostr pubkey stored in their
    /// instant message addresses. Call this on app launch and after changes.
    public func fetchLinkedContacts() async {
        guard permissionStatus == .authorized else { return }
        isLoading = true
        defer { isLoading = false }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var found: [LinkedContact] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                for im in contact.instantMessageAddresses {
                    let addr = im.value
                    guard addr.service == ContactsIntegrationService.nostrIMService,
                          addr.username.count == 64 else { continue }
                    let linked = LinkedContact(
                        contactId: contact.identifier,
                        nostrPubkeyHex: addr.username,
                        displayName: Self.fullName(for: contact),
                        thumbnailData: contact.thumbnailImageData
                    )
                    found.append(linked)
                }
            }
        } catch {
            print("[ContactsIntegrationService] fetch error: \(error)")
        }

        linkedContacts = found.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Link / unlink

    /// Writes a Nostr pubkey into the contact's instant message addresses.
    /// Overwrites any existing "Nostr" entry for this contact.
    public func link(pubkeyHex: String, to contactId: String) async throws {
        guard permissionStatus == .authorized else { return }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
        ]
        let contact = try store.unifiedContact(withIdentifier: contactId, keysToFetch: keys)
        let mutable = contact.mutableCopy() as! CNMutableContact

        // Remove existing Nostr IM entry (if any) before adding the new one
        mutable.instantMessageAddresses = mutable.instantMessageAddresses.filter {
            $0.value.service != ContactsIntegrationService.nostrIMService
        }
        let nostrIM = CNLabeledValue(
            label: CNLabelOther,
            value: CNInstantMessageAddress(
                username: pubkeyHex,
                service: ContactsIntegrationService.nostrIMService
            )
        )
        mutable.instantMessageAddresses.append(nostrIM)

        let saveRequest = CNSaveRequest()
        saveRequest.update(mutable)
        try store.execute(saveRequest)
        await fetchLinkedContacts()
    }

    /// Removes the Nostr pubkey from a contact's instant message addresses.
    public func unlink(contactId: String) async throws {
        guard permissionStatus == .authorized else { return }

        let keys: [CNKeyDescriptor] = [
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
        ]
        let contact = try store.unifiedContact(withIdentifier: contactId, keysToFetch: keys)
        let mutable = contact.mutableCopy() as! CNMutableContact
        mutable.instantMessageAddresses = mutable.instantMessageAddresses.filter {
            $0.value.service != ContactsIntegrationService.nostrIMService
        }
        let saveRequest = CNSaveRequest()
        saveRequest.update(mutable)
        try store.execute(saveRequest)
        await fetchLinkedContacts()
    }

    // MARK: - Address book picker data

    /// Returns all contacts (name + identifier) for display in the link picker.
    /// Does NOT read message data — only name and identifier fields.
    public func allContacts() throws -> [AddressBookEntry] {
        guard permissionStatus == .authorized else { return [] }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var results: [AddressBookEntry] = []
        try store.enumerateContacts(with: request) { contact, _ in
            results.append(AddressBookEntry(
                id: contact.identifier,
                displayName: Self.fullName(for: contact),
                thumbnailData: contact.thumbnailImageData
            ))
        }
        return results.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Helpers

    private static func fullName(for contact: CNContact) -> String {
        let full = CNContactFormatter.string(from: contact, style: .fullName)
        return full ?? contact.organizationName.isEmpty ? contact.organizationName : "Unknown"
    }
}

// MARK: - AddressBookEntry

public struct AddressBookEntry: Identifiable, Sendable {
    public let id: String        // CNContact.identifier
    public let displayName: String
    public let thumbnailData: Data?

    public var thumbnail: UIImage? { thumbnailData.flatMap { UIImage(data: $0) } }
}
