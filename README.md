# mChat

**A native, open, privacy-first iOS chat app — your WhatsApp replacement that shares nothing with anyone.**

mChat is built on open protocols and cryptographic identities. No phone number. No central server. No company reading your messages. Your private key never leaves your device.

---

## Why mChat?

| WhatsApp | mChat |
|---|---|
| Phone number required | Keypair — no registration |
| Meta reads metadata | End-to-end encrypted content + sealed sender (NIP-17) |
| One company controls the server | Dozens of independent relay operators |
| Closed source | Fully open source (MIT) |
| Contact list uploaded to Meta | Contacts stay on your device |

---

## Features (Phase 1)

- **Cryptographic identity** — secp256k1 keypair, stored in iOS Keychain, never transmitted
- **1:1 encrypted messaging** — NIP-04 (AES-256-CBC + ECDH) over the Nostr relay network
- **Group chat** — NIP-28 channel support (Phase 2)
- **Multi-relay** — broadcasts to multiple independent relays simultaneously; no single point of failure
- **iOS Contacts integration** — link Nostr pubkeys to address book entries; no server-side matching
- **Local persistence** — SwiftData keeps full message history across app restarts
- **Contact resolution** — fetches display names and avatars from Nostr metadata events
- **Multi-protocol architecture** — `MessagingBackend` abstraction ready for Matrix, XMPP, SimpleX, and more

---

## Architecture

```
┌─────────────────────────────────────────────┐
│              iOS App (SwiftUI)               │
│  Onboarding · Conversations · Chat · Profile │
└───────────────────┬─────────────────────────┘
                    │
┌───────────────────▼─────────────────────────┐
│              ChatService                     │
│   routes messages to the correct backend     │
└───┬───────────────┬──────────────────────────┘
    │               │
┌───▼──────┐  ┌─────▼──────────────────────┐
│  Nostr   │  │  Matrix / XMPP / SimpleX   │
│ Backend  │  │  (Phase 3 — plug-in ready) │
└───┬──────┘  └────────────────────────────┘
    │
┌───▼──────────────────────────────────────┐
│          mChatCore  (Swift Package)       │
│  NostrKeyPair · NostrEvent · NIP04        │
│  NostrRelay · NostrClient · NostrFilter   │
│  MessagingBackend protocol                │
└──────────────────────────────────────────┘
```

Adding a new protocol requires only a new `MessagingBackend` conformance — no UI or storage changes.

---

## Getting Started

### Prerequisites

- macOS 14+ (Sonoma)
- Xcode 15.2+
- iOS 17+ device or simulator

### Setup

See **[SETUP.md](SETUP.md)** for the full step-by-step Xcode guide. The short version:

1. Clone this repo
2. Open `Package.swift` in Xcode — SPM resolves `secp256k1.swift` automatically
3. Create a new Xcode iOS App project, add `mChatCore` as a local package
4. Add the `Sources/mChat/` folder to the Xcode target
5. Add `NSContactsUsageDescription` to `Info.plist`
6. Build and run on an iOS 17 simulator

On first launch, tap **Create New Identity** — your keypair is generated on-device and stored in the Keychain.

---

## Project Layout

```
mChat/
├── Package.swift                   # mChatCore SPM package
├── REQUIREMENTS.md                 # Full functional & non-functional requirements
├── SETUP.md                        # Xcode setup guide
├── docs/
│   ├── nostr.md                    # Nostr protocol deep-dive
│   ├── p2p-technologies.md         # P2P & decentralised messaging landscape
│   └── protocol-candidates.md      # Future protocol recommendations (Matrix, SimpleX…)
├── Sources/
│   ├── mChatCore/                  # Platform-independent core library
│   │   ├── Backend/
│   │   │   ├── MessagingBackend.swift   # Protocol abstraction
│   │   │   └── NostrBackend.swift       # Nostr implementation
│   │   ├── Crypto/
│   │   │   └── NIP04.swift              # AES-256-CBC encrypted DMs
│   │   ├── Models/
│   │   │   ├── ChatMessage.swift
│   │   │   ├── Contact.swift
│   │   │   └── Conversation.swift       # 1:1 + group, any protocol
│   │   └── Nostr/
│   │       ├── NostrClient.swift        # Multi-relay orchestrator
│   │       ├── NostrEvent.swift         # NIP-01 event model + signing
│   │       ├── NostrFilter.swift        # Subscription filters
│   │       ├── NostrKeyPair.swift       # secp256k1 identity
│   │       └── NostrRelay.swift         # WebSocket relay actor
│   └── mChat/                      # iOS app (add to Xcode project)
│       ├── App/
│       │   └── mChatApp.swift
│       ├── Services/
│       │   ├── ChatService.swift        # Multi-backend orchestrator
│       │   ├── ContactsIntegrationService.swift  # iOS Contacts (CNContactStore)
│       │   └── IdentityService.swift    # Keychain key management
│       ├── Storage/
│       │   ├── MessageStore.swift       # SwiftData wrapper
│       │   ├── StoredMessage.swift
│       │   ├── StoredConversation.swift
│       │   └── StoredContact.swift
│       └── Views/
│           ├── OnboardingView.swift
│           ├── ConversationListView.swift
│           ├── ChatView.swift
│           ├── ContactsView.swift
│           └── ProfileView.swift
└── Tests/
    └── mChatCoreTests/             # Unit tests (swift test / ⌘U)
```

---

## Roadmap

| Phase | Status | What's included |
|---|---|---|
| **1 — Foundation** | ✅ Done | Nostr identity, NIP-04 DMs, multi-relay, SwiftUI app, Contacts integration, SwiftData persistence |
| **2 — Privacy & Groups** | 🔜 Next | NIP-17 Gift Wrap (sealed sender), NIP-44 encryption, NIP-28 groups, relay management UI |
| **3 — Multi-Protocol** | 📅 Planned | Matrix backend (Olm/Megolm), SimpleX backend (no identifiers) |
| **4 — Breadth** | 📅 Planned | XMPP+OMEMO, Session, Delta Chat (email transport) |

See [docs/protocol-candidates.md](docs/protocol-candidates.md) for the full protocol evaluation and reasoning.

---

## Documentation

| Document | Description |
|---|---|
| [REQUIREMENTS.md](REQUIREMENTS.md) | Functional and non-functional requirements, open questions |
| [SETUP.md](SETUP.md) | Xcode project setup step-by-step |
| [docs/nostr.md](docs/nostr.md) | Nostr protocol deep-dive: events, encryption, relays, NIPs |
| [docs/p2p-technologies.md](docs/p2p-technologies.md) | P2P landscape: Nostr, Matrix, Pear, XMPP, libp2p, Briar… |
| [docs/protocol-candidates.md](docs/protocol-candidates.md) | Future protocol candidates with prioritised recommendations |

---

## Privacy Principles

1. **Private key never leaves your device** — stored in iOS Keychain, never transmitted
2. **No phone number, no email, no registration** — identity is a cryptographic keypair
3. **No contact list uploaded** — address book integration is fully on-device
4. **No telemetry** — zero analytics by default
5. **Open source** — every line is auditable

---

## Contributing

Issues and pull requests are welcome. See [REQUIREMENTS.md](REQUIREMENTS.md) for the current scope and open questions.

This project follows the development standards defined in [zehrer/development](https://github.com/zehrer/development): branch protection, PR-based workflow, and conventional commit messages.

---

## License

MIT — see [LICENSE](LICENSE).
