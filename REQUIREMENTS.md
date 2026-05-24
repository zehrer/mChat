# mOpenChat – Requirements Document

**Version:** 0.1 (initial)
**Date:** 2026-05-21
**Goal:** A native iOS chat application that replaces WhatsApp without sharing private data with any third party.

---

## 1. Vision

mOpenChat is a privacy-first, open-source mobile messaging application — a native and open source chat client supporting peer-to-peer and other protocols. Users own their identity (a cryptographic keypair), their messages travel end-to-end encrypted, and no single company can read, censor, or monetise their conversations.

> Naming note: the user-facing app is **mOpenChat**; the source repo, Xcode project, Swift modules (`mChat`, `mChatCore`), and bundle identifier remain `mChat` because that name is already taken on the App Store.

---

## 2. Non-Negotiable Privacy Principles

| Principle | Implementation |
|---|---|
| No phone number required | Identity = secp256k1 keypair (Nostr) |
| Private key never leaves the device | Stored in iOS Keychain, never transmitted |
| End-to-end encrypted messages | NIP-04 (AES-256-CBC + ECDH) → NIP-44 upgrade path |
| No central server storing messages | Nostr relays are dumb forwarders; they see only encrypted blobs |
| No tracking or analytics by default | Zero telemetry in-app |
| Open source | All code published under MIT licence |

---

## 3. Functional Requirements

### 3.1 Identity

| ID | Requirement |
|---|---|
| ID-01 | The app shall generate a secp256k1 keypair on first launch. |
| ID-02 | The private key shall be stored in the iOS Keychain with `kSecAttrAccessibleAfterFirstUnlock`. |
| ID-03 | The user shall be able to import an existing identity via hex private key. |
| ID-04 | The user shall be able to export (display) their private key after authentication. |
| ID-05 | The user shall be able to set a display name, avatar, about text, and NIP-05 identifier (profile). |
| ID-06 | Deleting an identity shall remove the private key from the Keychain and wipe local message data. |

### 3.2 Messaging – 1:1 Chat

| ID | Requirement |
|---|---|
| MSG-01 | The app shall support sending and receiving end-to-end encrypted direct messages between two users. |
| MSG-02 | Messages shall be encrypted with NIP-04 (AES-256-CBC, ECDH shared key) initially; NIP-44 in Phase 2. |
| MSG-03 | The sender's address is the recipient's Nostr public key (hex). |
| MSG-04 | The app shall display delivery status: sending / sent / failed. |
| MSG-05 | The app shall display a scrollable, chronologically ordered message history. |
| MSG-06 | Messages shall be stored locally (SwiftData) and survive app restarts. |
| MSG-07 | The app shall load recent message history from relays on first open. |

### 3.3 Messaging – Group Chat

| ID | Requirement |
|---|---|
| GRP-01 | The app shall support creation of group conversations with a name and multiple members. |
| GRP-02 | Group messages shall use NIP-28 (Nostr channels, kind 42) for Nostr backend. |
| GRP-03 | The creator of a group shall be able to add and remove members. |
| GRP-04 | Group metadata (name, member list) shall be persisted locally. |
| GRP-05 | Group message history shall be loaded from relays on demand. |

### 3.4 Contacts

| ID | Requirement |
|---|---|
| CON-01 | The app shall resolve contact display names from Nostr kind-0 metadata events. |
| CON-02 | The app shall display a NIP-05 verified badge for contacts with a valid NIP-05 identifier. |
| CON-03 | Contacts shall be stored locally for offline access. |
| CON-04 | The user shall be able to search contacts by name or public key. |
| CON-05 | The app shall integrate with the iOS Contacts app (CNContactStore). |
| CON-06 | The user shall be able to link a Nostr pubkey to any existing iOS contact. The pubkey is stored in the contact's instant message addresses field (service: "Nostr"). |
| CON-07 | The user shall be able to unlink a Nostr pubkey from an iOS contact. |
| CON-08 | The app shall **never** upload the user's contact list to any server. No server-side phone-number-to-pubkey matching shall be performed. |
| CON-09 | Linked iOS contacts shall appear in the "From Address Book" section of the Contacts tab, showing the contact's photo and full name from the address book. |
| CON-10 | The app shall request Contacts permission only when the user initiates the address book integration, with a clear explanation shown before the system prompt. |

### 3.5 Relay Management

| ID | Requirement |
|---|---|
| REL-01 | The app shall connect to at least 4 well-known public relays by default. |
| REL-02 | The user shall be able to add, remove, and reorder relays. |
| REL-03 | The app shall automatically reconnect to relays after network interruptions. |
| REL-04 | Events shall be broadcast to all connected relays simultaneously. |
| REL-05 | The app shall support connecting to private (self-hosted) relays via WSS URL. |

### 3.6 Multi-Protocol Support (Phase 2+)

| ID | Requirement |
|---|---|
| PRO-01 | The architecture shall support pluggable protocol backends behind a `MessagingBackend` interface. |
| PRO-02 | A Matrix/Element backend shall be addable without changes to the UI layer. |
| PRO-03 | An XMPP backend shall be addable without changes to the UI layer. |
| PRO-04 | Conversations shall be tagged with their originating protocol. |
| PRO-05 | The user shall be able to manage multiple accounts/protocols simultaneously. |

---

## 4. Non-Functional Requirements

### 4.1 Performance

| ID | Requirement |
|---|---|
| PERF-01 | The app shall launch to the conversation list in under 1.5 seconds on an iPhone 12. |
| PERF-02 | Sending a message shall produce UI feedback within 100 ms of the tap. |
| PERF-03 | Message decryption shall not block the main thread. |
| PERF-04 | The local message store shall handle at least 100,000 messages without degradation. |

### 4.2 Security

| ID | Requirement |
|---|---|
| SEC-01 | The app shall not log message content to the console in release builds. |
| SEC-02 | The private key shall be inaccessible if the device is locked (Keychain protection). |
| SEC-03 | The app shall validate event signatures before displaying incoming messages. |
| SEC-04 | The app shall use TLS (WSS) for all relay connections; plain WS shall be disallowed. |
| SEC-05 | The app shall not transmit any analytics or crash data without explicit user opt-in. |

### 4.3 Usability

| ID | Requirement |
|---|---|
| UX-01 | The app shall follow iOS Human Interface Guidelines. |
| UX-02 | The app shall support Dynamic Type and VoiceOver. |
| UX-03 | The app shall support both light and dark mode. |
| UX-04 | The app shall run on iPhone (iOS 17+); iPad support is optional. |

### 4.4 Reliability

| ID | Requirement |
|---|---|
| REL-01 | The app shall function for reading cached messages with no network connection. |
| REL-02 | Message sending shall retry automatically when connectivity is restored. |
| REL-03 | WebSocket connections shall reconnect with exponential backoff (max 60 s). |

---

## 5. Out of Scope (v1)

- Voice and video calls
- File and media attachments (images, video)
- Push notifications (APNs)
- iPad-optimised layout
- macOS companion app
- NIP-05 verification requests (display only)
- NIP-44 encryption (upgrade from NIP-04 in Phase 2)
- Matrix / XMPP backends (architecture is ready; implementation is Phase 2)

---

## 6. Phased Delivery

### Phase 1 – Foundation (current)
- Nostr identity generation and Keychain storage
- NIP-04 encrypted 1:1 DMs
- Multi-relay connection management
- SwiftUI app: onboarding, conversation list, chat view, profile
- `MessagingBackend` protocol abstraction for future protocols
- Unit tests for crypto and Nostr protocol logic

### Phase 2 – Groups & Polish
- NIP-28 group channels (kind 42)
- NIP-44 encrypted DMs (upgrade from NIP-04)
- NIP-17 Gift Wrap for sealed-sender privacy
- Relay user management UI
- Local SwiftData message persistence
- Contact list with NIP-05 verification

### Phase 3 – Multi-Protocol
- Matrix backend (matrix-swift-sdk)
- XMPP backend
- Unified conversation inbox across protocols
- Cross-protocol contact book

### Phase 4 – Advanced Features
- Push notifications (APNs + relay webhooks)
- Media attachments (NIP-94 / NIP-96)
- Voice messages
- iPad layout
- macOS (Catalyst or native)

---

## 7. Open Questions

| # | Question | Owner |
|---|---|---|
| Q1 | Should we self-host a relay for reliability and reduced metadata exposure? | @zehrer |
| Q2 | Which Matrix homeserver should serve as the default for the Matrix backend? | @zehrer |
| Q3 | Do we adopt NIP-17 Gift Wrap from the start or upgrade from NIP-04 in Phase 2? | Engineering |
| Q4 | App Store distribution or TestFlight only for v1? | @zehrer |
| Q5 | Should the app support multiple Nostr identities per device? | @zehrer |
