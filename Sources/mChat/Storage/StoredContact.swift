import Foundation
import SwiftData

@Model
final class StoredContact {
    @Attribute(.unique) var pubkeyHex: String
    var displayName: String?
    var about: String?
    var pictureURLString: String?
    var nip05: String?
    var lastSeen: Date?

    init(from contact: Contact) {
        pubkeyHex      = contact.pubkeyHex
        displayName    = contact.displayName
        about          = contact.about
        pictureURLString = contact.pictureURL?.absoluteString
        nip05          = contact.nip05
        lastSeen       = contact.lastSeen
    }

    func toContact() -> Contact {
        var c = Contact(pubkeyHex: pubkeyHex)
        c.displayName = displayName
        c.about       = about
        c.pictureURL  = pictureURLString.flatMap { URL(string: $0) }
        c.nip05       = nip05
        c.lastSeen    = lastSeen
        return c
    }
}
