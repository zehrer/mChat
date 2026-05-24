# Chat Protocol Candidates for mOpenChat

*An evaluation of messaging protocols that could be added as `MessagingBackend` implementations, with prioritised recommendations.*

---

## How to Read This Document

mOpenChat's `MessagingBackend` protocol means adding a new chat network is a self-contained module — no UI or storage changes needed. The question is: which protocols are worth building, and in what order?

Each entry is scored across five axes relevant to mOpenChat's goals:

| Axis | What it means |
|---|---|
| **Privacy** | Metadata protection, no phone number, operator visibility |
| **E2E encryption** | Is content encrypted end-to-end by default? |
| **Decentralisation** | Can users avoid any single company's infrastructure? |
| **iOS feasibility** | Quality of available Swift/iOS libraries |
| **User reach** | How many potential contacts already use it? |

---

## Recommendations at a Glance

| Protocol | Priority | Why |
|---|---|---|
| **Matrix** | 🟢 High — Phase 3 | Best group chat E2E encryption, self-hostable, iOS SDK exists |
| **SimpleX Chat** | 🟢 High — Phase 3 | Strongest privacy design of any protocol, no identifiers at all |
| **XMPP + OMEMO** | 🟡 Medium — Phase 4 | Huge existing user base, mature, bridges to legacy systems |
| **Session** | 🟡 Medium — Phase 4 | No phone number, onion routing, Signal-compatible crypto |
| **Delta Chat** | 🟡 Medium — Phase 4 | Works over standard email — zero new infrastructure |
| **Signal Protocol (libsignal)** | 🟠 Transport layer | Use as crypto layer over Nostr/Matrix, not a standalone backend |
| **Telegram (MTProto)** | 🔴 Low | Proprietary, not E2E by default, conflicts with privacy goals |
| **RCS** | 🔴 Low | Carrier-controlled, US-centric, conflicts with decentralisation goal |
| **IRC** | ⚪ Informational | No E2E, but useful as a read-only bridge for developer communities |

---

## 1. Matrix / Element Protocol 🟢 High Priority

**Recommendation: implement in Phase 3**

### Overview

Matrix is a federated, open standard for real-time communication. Users register on a homeserver (matrix.org or self-hosted). Homeservers sync with each other — similar to email federation — but the Olm/Megolm encryption layer means homeservers only ever see ciphertext.

```
Alice (matrix.org) ←──── federation ────→ Bob (homeserver.company.org)
        │                                          │
    Olm session                               Olm session
  (E2E encrypted,                           (E2E encrypted,
   server sees only                          server sees only
   ciphertext)                               ciphertext)
```

### Encryption

Matrix uses two algorithms from the [libolm](https://gitlab.matrix.org/matrix-org/olm) library:

- **Olm** — 1:1 Double Ratchet sessions (same algorithm as Signal). Provides forward secrecy.
- **Megolm** — Group ratchet. One sender ratchet per room, shared to all members. Scales to large groups; Olm does not.

```
1:1 chat  →  Olm   (per-message key rotation, forward secrecy)
Group     →  Megolm (per-session key, rotated periodically or on member change)
```

### Privacy properties

| Property | Status |
|---|---|
| No phone number | ✅ username@server only |
| E2E by default | ✅ in modern clients (was opt-in historically) |
| Server sees metadata | ⚠️ homeserver sees room membership, timestamps |
| Self-hostable | ✅ Synapse, Dendrite, Conduit |
| Cross-signing / verified sessions | ✅ device verification via QR or emoji |

### Why it fits mOpenChat

- **Best group chat story**: Megolm is the most mature E2E group encryption available
- **Bridges**: Matrix bridges exist for Telegram, WhatsApp, Discord, Slack, IRC — adding Matrix to mOpenChat effectively adds read-only access to all of those
- **Enterprise use case**: Many companies self-host Matrix (Element provides commercial support)
- **Large user base**: Element has millions of users; matrix.org homeserver is the default

### iOS implementation path

The [Matrix Swift SDK](https://github.com/matrix-org/matrix-ios-sdk) is mature and actively maintained by Element. It handles all crypto, sync, and room state.

```swift
// Future MatrixBackend.swift skeleton
actor MatrixBackend: MessagingBackend {
    let chatProtocol: ChatProtocol = .matrix
    private let client: MXRestClient
    private let session: MXSession

    func connect() async throws {
        // Authenticate via password or SSO
        // Start sync loop
    }

    func send(text: String, in conversation: Conversation) async throws -> ChatMessage {
        // MXRoom.send(textMessage:)
    }
}
```

**Estimated effort:** Medium — SDK does the heavy lifting; main work is mapping Matrix room/event model to mOpenChat's Conversation/ChatMessage types.

---

## 2. SimpleX Chat 🟢 High Priority

**Recommendation: implement in Phase 3, alongside Matrix**

### Overview

[SimpleX Chat](https://simplex.chat) is arguably the most privacy-preserving messaging protocol available today. Its key insight: **users have no identifier at all** — not a phone number, not a username, not a public key.

Instead of an identity, SimpleX uses **one-way message queues**:

```
Alice creates a queue on a relay server → gets a contact link (QR / URL)
Bob scans Alice's contact link → gets Alice's queue address
Bob creates his own queue → sends address to Alice through her queue
Now both have a one-way channel to each other, with no shared identity
```

### Why "no identifier" matters

Every other protocol (including Nostr) has a persistent identity (pubkey, phone number, username) that can be used to:
- Enumerate contacts ("who follows this pubkey?")
- Correlate messages across time
- Target a specific person

SimpleX has none of this. Each contact relationship is a pair of independent queues. A relay server hosting Alice's queue knows only that *someone* is sending messages to that queue — it doesn't know who Alice is, or who the sender is.

### Encryption

- **Double Ratchet** (Signal Protocol) for all messages — same algorithm as Signal/WhatsApp
- **NaCl box** for server-level transport encryption
- **SMP protocol** (SimpleX Messaging Protocol) is the wire format

### Privacy properties

| Property | Status |
|---|---|
| No identifier of any kind | ✅ (unique in the industry) |
| E2E by default | ✅ |
| Server sees metadata | ❌ Server cannot correlate sender/recipient — no persistent IDs |
| Self-hostable | ✅ SMP server is simple to run |
| Quantum-resistant option | ✅ Post-quantum Kyber key exchange |

### iOS implementation path

SimpleX Chat has a [Swift library](https://github.com/simplex-chat/simplex-chat) (the iOS app is native Swift). The core logic is a Haskell library exposed via C FFI, which adds complexity — wrapping it in Swift requires bridging the C interface.

**Estimated effort:** High — C/Haskell FFI bridging. However the payoff is exceptional privacy for users who care most.

**Alternative**: Implement the SMP protocol directly in Swift (it is fully documented and not complex).

---

## 3. XMPP + OMEMO 🟡 Medium Priority

**Recommendation: Phase 4, after Matrix**

### Overview

XMPP (eXtensible Messaging and Presence Protocol) is a federated, XML-based messaging standard that has been an RFC since 1999. It is the most widely deployed open messaging protocol in existence — WhatsApp, Google Talk, and many enterprise systems were originally XMPP.

**OMEMO** ([XEP-0384](https://xmpp.org/extensions/xep-0384.html)) adds Signal Protocol Double Ratchet encryption to XMPP, bringing modern E2E security to the protocol.

### Why include it

- **Largest addressable federated user base** of any open protocol
- Many governments, universities, and enterprises run XMPP servers
- German healthcare system uses XMPP; many German government departments
- Enables mOpenChat to talk to users on well-established Jabber/XMPP deployments

### Privacy properties

| Property | Status |
|---|---|
| No phone number | ✅ `user@server.org` only |
| E2E by default | ⚠️ OMEMO must be explicitly enabled; not all clients support it |
| Server sees metadata | ⚠️ Server sees sender, recipient, timestamp (like Matrix) |
| Self-hostable | ✅ Prosody, ejabberd, Openfire |

### iOS implementation path

[XMPPFramework](https://github.com/robbiehanson/XMPPFramework) is a mature Swift/Obj-C library. Adding OMEMO requires a separate library (e.g. [swift-omemo](https://github.com/tigase/Martin) via Tigase's Martin framework).

**Estimated effort:** Medium-High — two libraries to integrate; OMEMO session management is non-trivial.

---

## 4. Session Protocol 🟡 Medium Priority

**Recommendation: Phase 4**

### Overview

[Session](https://getsession.org) is a fork of Signal that removes the phone number requirement entirely. It uses a decentralised network of nodes (the **Session Network**, formerly Lokinet) built on a modified version of the Tor onion routing concept.

```
Sender → onion-routed through 3 Session nodes → Recipient's swarm
```

Identity is a **session ID** — a 66-character public key. No registration, no phone number, no email.

### Key differences from Signal

| | Signal | Session |
|---|---|---|
| Identity | Phone number | Session ID (public key) |
| Servers | Signal's centralised servers | Decentralised node network |
| Metadata | Signal knows sender/recipient | Onion routing hides both |
| Open source | Protocol yes, server no | Fully open source |
| Key exchange | X3DH | No X3DH (trade-off: no pre-key bundles) |

### Privacy properties

| Property | Status |
|---|---|
| No phone number | ✅ |
| E2E default | ✅ Signal Double Ratchet |
| IP hidden | ✅ Onion routing by default |
| Decentralised | ✅ but Session Foundation still operates bootstrap nodes |
| Self-hostable | ⚠️ Partial — can run service nodes |

### iOS implementation path

Session's iOS app is open source Swift. The core library (`libsession-util`) is C++, exposed via Swift bindings.

**Estimated effort:** High — C++ FFI required, onion routing adds network complexity.

---

## 5. Delta Chat (Email-Based Messaging) 🟡 Medium Priority

**Recommendation: Phase 4 — highest "reach" of any option**

### Overview

[Delta Chat](https://delta.chat) is a messenger that uses **email as its transport layer**. Messages are sent as MIME emails over SMTP/IMAP. End-to-end encryption is provided by [Autocrypt](https://autocrypt.org) (OpenPGP).

This means Delta Chat works with **any email provider** — Gmail, iCloud, self-hosted — with no new infrastructure. Every email user is a potential contact.

```
mOpenChat user                   Delta Chat user / any email client
    │                                    │
    ├── SMTP → email provider → IMAP ───→│ appears as email
    │                                    │
    └── E2E encrypted with Autocrypt ────┘ (if both support it)
```

### Why it's interesting for mOpenChat

- **Largest possible reach**: 4+ billion email users are potential contacts
- **Zero new infrastructure**: uses existing email providers
- **Fallback to plaintext**: if the other party doesn't support Autocrypt, message still delivers (as cleartext email — privacy degrades gracefully)
- **Works everywhere**: useful for communicating with contacts who won't install a new app

### Privacy properties

| Property | Status |
|---|---|
| No new account | ✅ reuses existing email |
| E2E by default | ⚠️ only when both parties support Autocrypt |
| Metadata | ⚠️ email provider sees sender, recipient, timestamp |
| Self-hostable | ✅ use any SMTP/IMAP server |

### iOS implementation path

Requires an SMTP/IMAP library and an OpenPGP library. Options:
- [MailCore2](https://github.com/MailCore/mailcore2) — SMTP/IMAP (C++ core)
- [ObjectivePGP](https://github.com/krzyzanowskim/ObjectivePGP) — OpenPGP in Swift

**Estimated effort:** Medium — email protocol is well-understood; Autocrypt key exchange is straightforward.

---

## 6. Signal Protocol as a Crypto Layer 🟠 Not a Standalone Backend

**Recommendation: Use as an encryption upgrade within existing backends**

The **Signal Protocol** (Double Ratchet + X3DH) is the gold standard for E2E encryption. It is used by Signal, WhatsApp, Google Messages, Wire, and Facebook Messenger.

Critically: the protocol is separable from Signal's server infrastructure. **LibSignal** (the open-source library) can be used with any transport.

### Relevance to mOpenChat

Rather than building a "Signal backend", the Signal Protocol could be layered on top of existing transports:

- **Nostr + Signal**: Use X3DH for initial key exchange (via Nostr events), then Double Ratchet for messages. Provides forward secrecy stronger than NIP-04.
- **Matrix + Signal**: Matrix already uses Olm (which is based on Double Ratchet). This is largely the same algorithm.

Apple's [CryptoKit](https://developer.apple.com/documentation/cryptokit) provides many of the primitives (X25519, AES-GCM, HKDF, HMAC). A pure Swift Double Ratchet implementation is feasible.

---

## 7. Telegram (MTProto) 🔴 Low Priority

**Recommendation: consider only as a read bridge, not a full backend**

### Why not a priority

Telegram's **MTProto** protocol is proprietary and its privacy properties conflict with mOpenChat's goals:

| Issue | Detail |
|---|---|
| Not E2E by default | Group chats and cloud chats are stored unencrypted on Telegram's servers |
| Secret chats only | E2E is opt-in ("Secret Chat"), not available in groups |
| Proprietary | MTProto is designed by Telegram, not an open standard |
| Phone number required | Account tied to phone number |
| Centralised | All traffic routes through Telegram's servers |

### When it makes sense

Telegram has 900+ million users. A **read-only bridge** (via [Telegram Bot API](https://core.telegram.org/bots/api) or the unofficial [TDLib](https://core.telegram.org/tdlib)) could let mOpenChat users receive Telegram messages — useful for migrating contacts.

---

## 8. RCS (Rich Communication Services) 🔴 Low Priority

**Recommendation: skip**

RCS is the carrier-network upgrade to SMS, now supported by Google Messages, Samsung Messages, and since iOS 18, Apple Messages.

| Issue | Detail |
|---|---|
| Carrier-controlled | No self-hosting; dependent on mobile operators |
| No universal E2E | Google's implementation has E2E; carrier-native RCS does not |
| Not decentralised | Each carrier operates its own RCS hub |
| API access | No public API; requires carrier agreements |

RCS serves a different use case (interoperability with SMS users) and cannot be implemented as a standalone backend without carrier partnerships.

---

## 9. IRC 🔴 Low Priority / Bridge Only

IRC is the oldest open chat protocol (1988). It has no E2E encryption, no persistent message history by default, and primitive identity.

**Only worth considering as a bridge** for developer communities (many open-source projects use Libera.chat). A lightweight IRC connector could let mOpenChat users lurk in `#swift` or `#ios` channels without opening a separate app.

---

## Implementation Roadmap Recommendation

```
Phase 3  (after SwiftData, NIP-17, NIP-44 are done)
├── Matrix backend
│   ├── matrix-ios-sdk integration
│   ├── MatrixBackend: MessagingBackend
│   └── 1:1 Olm + group Megolm
└── SimpleX backend
    ├── SMP protocol implementation in Swift (or C FFI)
    └── No-identifier 1:1 chat

Phase 4
├── XMPP + OMEMO backend
│   └── XMPPFramework + OMEMO extension
├── Session backend
│   └── libsession-util Swift bindings
└── Delta Chat (email) backend
    └── SMTP/IMAP + Autocrypt

Bridges (lower priority, read-only)
├── Telegram bridge (TDLib)
└── IRC bridge
```

### Decision criteria for ordering

1. **Matrix first** because it has the best iOS SDK, the best group chat story, and it enables bridges to everything else.
2. **SimpleX second** because it offers the privacy guarantee that no other protocol can match — a compelling differentiator for privacy-conscious users.
3. **XMPP third** because of the large existing user base and enterprise deployment footprint.
4. **Session and Delta Chat** serve specific user needs (Session: maximum anonymity; Delta Chat: maximum reach) and are lower complexity than Matrix.

---

## Evaluation Matrix

| Protocol | Privacy | E2E | Decentralised | iOS libs | Reach | Effort | **Verdict** |
|---|---|---|---|---|---|---|---|
| **Matrix** | ★★★★☆ | ★★★★★ | ★★★★☆ | ★★★★★ | ★★★★☆ | Medium | 🟢 Phase 3 |
| **SimpleX** | ★★★★★ | ★★★★★ | ★★★★☆ | ★★★☆☆ | ★★☆☆☆ | High | 🟢 Phase 3 |
| **XMPP+OMEMO** | ★★★☆☆ | ★★★★☆ | ★★★★★ | ★★★★☆ | ★★★★★ | Med-High | 🟡 Phase 4 |
| **Session** | ★★★★★ | ★★★★★ | ★★★★☆ | ★★★☆☆ | ★★★☆☆ | High | 🟡 Phase 4 |
| **Delta Chat** | ★★★☆☆ | ★★★☆☆ | ★★★★★ | ★★★☆☆ | ★★★★★ | Medium | 🟡 Phase 4 |
| **Telegram** | ★★☆☆☆ | ★★☆☆☆ | ★☆☆☆☆ | ★★★★☆ | ★★★★★ | Medium | 🔴 Bridge only |
| **RCS** | ★★☆☆☆ | ★★★☆☆ | ★☆☆☆☆ | ★☆☆☆☆ | ★★★★★ | Very High | 🔴 Skip |
| **IRC** | ★☆☆☆☆ | ★☆☆☆☆ | ★★★★★ | ★★★☆☆ | ★★★☆☆ | Low | 🔴 Bridge only |
