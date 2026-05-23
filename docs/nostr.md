# Nostr — Deep Dive

*Notes on the Nostr Protocol as used in mChat*

---

## What is Nostr?

**Nostr** (Notes and Other Stuff Transmitted by Relays) is a simple, open protocol for decentralised social messaging and communication. It was designed by [fiatjaf](https://github.com/fiatjaf) around 2020 and has grown into a substantial ecosystem with hundreds of clients and thousands of relays.

Unlike Matrix or XMPP, Nostr deliberately avoids federation between servers. Instead, **clients talk directly to relays**. Relays are dumb — they store events and forward them, but they have no understanding of identity or relationships. The client owns everything.

---

## Core Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                            CLIENT                               │
│  (mChat, Damus, Primal, …)                                      │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐        │
│  │  Keypair     │   │  Event       │   │  Filter /    │        │
│  │  (identity)  │   │  (message)   │   │  Subscription│        │
│  └──────────────┘   └──────────────┘   └──────────────┘        │
└─────────┬───────────────────┬───────────────────┬──────────────┘
          │ WSS               │ WSS               │ WSS
          ▼                   ▼                   ▼
    ┌──────────┐        ┌──────────┐        ┌──────────┐
    │  Relay A │        │  Relay B │        │  Relay C │
    │ (public) │        │ (private)│        │ (paid)   │
    └──────────┘        └──────────┘        └──────────┘
```

**Key insight:** Clients connect to *multiple* relays simultaneously. Events are broadcast to all of them. This means:
- No single relay can censor you (use another)
- No single relay failure loses your messages (redundancy)
- Relay operators cannot forge messages (cryptographic signatures)

---

## Identity: secp256k1 Keypairs

Every Nostr identity is a **secp256k1 keypair** — the same elliptic curve used by Bitcoin.

```
Private key:  32 bytes (256 bits of entropy)   — NEVER share this
Public key:   32 bytes (x-coordinate only)     — this is your "address"
```

### Why secp256k1?

- Battle-tested in Bitcoin since 2009
- Enables **Schnorr signatures** (BIP-340) — smaller, faster, non-malleable
- Enables **ECDH key agreement** — the basis for NIP-04/NIP-44 encryption
- No trusted setup, no certificate authority

### Key representations

Nostr uses two encodings:

| Format | Example | Use |
|---|---|---|
| **Hex** | `3bf0c63fcb...` (64 chars) | Wire format in events |
| **Bech32 (NIP-19)** | `npub1...` / `nsec1...` | User-facing display |

`npub` = public key, `nsec` = private key (secret), `note` = event ID.

In mChat we use hex internally and can display bech32 in the UI (Phase 2).

### Key generation in mChat

```swift
// NostrKeyPair.swift
let privateKey = try secp256k1.Signing.PrivateKey(format: .compressed)
// Public key is the x-coordinate of the EC point (32 bytes)
let publicKeyBytes = Data(privateKey.publicKey.rawRepresentation.dropFirst())
```

The private key is stored in the **iOS Keychain** and never transmitted anywhere.

---

## Events: The Universal Data Type

Everything in Nostr is an **event** — a signed JSON object. There are no separate "message" or "profile" types at the protocol level; the `kind` field differentiates them.

### Event structure (NIP-01)

```json
{
  "id":         "32-byte hex SHA256 of the serialised event",
  "pubkey":     "32-byte hex public key of the author",
  "created_at": 1700000000,
  "kind":       1,
  "tags":       [["e", "<event-id>"], ["p", "<pubkey>"]],
  "content":    "Hello, Nostr!",
  "sig":        "64-byte hex Schnorr signature"
}
```

### Computing the event ID

The ID is **not** assigned by a server — it is computed deterministically by the client:

```
id = SHA256(
  JSON.stringify([
    0,
    pubkey,
    created_at,
    kind,
    tags,
    content
  ])
)
```

This canonical serialisation must use no extra whitespace and specific Unicode escaping (NIP-01 §Event Serialisation).

In mChat (`NostrEvent.swift`):
```swift
let serialized = "[0,\"\(pubkey)\",\(createdAt),\(kind),\(tagsStr),\"\(escapedContent)\"]"
let idData = Data(SHA256.hash(data: serialized.data(using: .utf8)!))
```

### Schnorr signatures

Events are signed with **BIP-340 Schnorr signatures** over the 32-byte event ID:

```swift
let xonly = signingKey.xonly
let signature = try xonly.signature(for: eventId)  // 64 bytes
```

Any client can verify a signature using only the author's public key — no trusted third party.

---

## Event Kinds

Kinds are integers. The range determines persistence behaviour on relays:

| Range | Behaviour |
|---|---|
| `0–9999` | Regular — stored indefinitely |
| `10000–19999` | Replaceable — relay keeps only the latest |
| `20000–29999` | Ephemeral — relay may not store at all |
| `30000–39999` | Parameterised replaceable |

### Kinds used by mChat

| Kind | Name | NIP | Used for |
|---|---|---|---|
| `0` | Metadata | NIP-01 | User profile (name, about, picture, NIP-05) |
| `4` | Encrypted DM | NIP-04 | 1:1 private messages (Phase 1) |
| `40` | Channel creation | NIP-28 | Create a group channel |
| `41` | Channel metadata | NIP-28 | Update group name/about |
| `42` | Channel message | NIP-28 | Group chat message |
| `1059` | Gift wrap | NIP-17 | Sealed-sender DM (Phase 2) |

---

## Tags

Tags attach metadata to events. Common tag types:

| Tag | Meaning |
|---|---|
| `["p", "<pubkey>"]` | References a user (recipient in DMs, mention in notes) |
| `["e", "<event-id>"]` | References another event (reply, reaction target) |
| `["t", "nostr"]` | Hashtag |
| `["r", "wss://relay.url"]` | Relay hint |
| `["d", "identifier"]` | Unique identifier for parameterised replaceable events |

---

## Relay Communication (NIP-01)

Clients communicate with relays over **WebSocket** using three message types:

### CLIENT → RELAY

```json
// Publish an event
["EVENT", { ...event object... }]

// Subscribe to a filter
["REQ", "subscription-id", { ...filter... }]

// Cancel a subscription
["CLOSE", "subscription-id"]
```

### RELAY → CLIENT

```json
// Deliver a matching event
["EVENT", "subscription-id", { ...event object... }]

// All stored events sent, now streaming live
["EOSE", "subscription-id"]

// Publish acknowledgement
["OK", "<event-id>", true, ""]

// Human-readable notice
["NOTICE", "message"]

// Subscription closed by relay
["CLOSED", "subscription-id", "reason"]
```

### Filters

A `REQ` filter tells the relay which events to send:

```json
{
  "authors": ["<pubkey1>", "<pubkey2>"],
  "kinds":   [0, 4],
  "#p":      ["<my-pubkey>"],
  "since":   1700000000,
  "until":   1700100000,
  "limit":   50
}
```

Multiple filters in one `REQ` are ORed together.

In mChat (`NostrFilter.swift`):
```swift
// Subscribe to incoming DMs
NostrFilter.incomingDMs(for: myPubkeyHex)
// → kinds: [4], #p: [myPubkeyHex], limit: 100

// Subscribe to user profiles
NostrFilter.metadata(for: [pubkey1, pubkey2])
// → kinds: [0], authors: [pubkey1, pubkey2]
```

---

## Encryption

### NIP-04 (current, Phase 1)

NIP-04 uses **AES-256-CBC** with a key derived from ECDH:

```
shared_key = ECDH(sender_privkey, recipient_pubkey).x  // 32-byte x-coordinate
iv         = random 16 bytes
ciphertext = AES-256-CBC(plaintext, key=shared_key, iv=iv, padding=PKCS7)
wire_format = base64(ciphertext) + "?iv=" + base64(iv)
```

Event structure:
```json
{
  "kind": 4,
  "pubkey": "<sender-pubkey>",
  "tags": [["p", "<recipient-pubkey>"]],
  "content": "base64ciphertext?iv=base64iv",
  "sig": "..."
}
```

**Privacy limitation:** The relay can see `sender_pubkey` and `recipient_pubkey` in plaintext. This is a **metadata leak** — the relay knows *who is talking to whom*, even if it cannot read the content.

### NIP-44 (planned, Phase 2)

NIP-44 replaces AES-256-CBC with **XChaCha20-Poly1305** (authenticated encryption) and improves the key derivation:

```
conversation_key = ECDH(privkey, pubkey)   // same ECDH
message_key      = HKDF-SHA256(conversation_key, nonce, "nip44-v2")
ciphertext       = XChaCha20-Poly1305(plaintext, key=message_key)
```

Improvements over NIP-04:
- Authenticated encryption (prevents tampering)
- Better key derivation (HKDF)
- Larger nonce (192-bit XChaCha vs 128-bit AES-CBC)
- Message padding (hides message length)

### NIP-17 Gift Wrap (Phase 2 — sealed sender)

NIP-17 solves the metadata leak. The actual DM event is wrapped in two layers:

```
Seal (kind 13):
  content = NIP-44-encrypt(
    key = ECDH(sender_privkey, recipient_pubkey),
    plaintext = signed_rumor_event        // the actual message, unsigned
  )
  pubkey = sender_pubkey
  sig    = schnorr(sender_privkey)

Gift Wrap (kind 1059):
  content = NIP-44-encrypt(
    key = ECDH(ephemeral_privkey, recipient_pubkey),
    plaintext = seal_event
  )
  pubkey = ephemeral_pubkey              // random throwaway key
  tags   = [["p", recipient_pubkey]]
```

**Result:** The relay only sees the gift wrap, whose author is a random throwaway key. The recipient's pubkey is visible (the relay needs it to route), but the *sender's* identity is hidden from the relay entirely.

---

## NIP-05: DNS-Based Identity Verification

NIP-05 lets users claim a human-readable identifier like `alice@example.com` and verify it proves control of the domain.

**Verification flow:**

```
1. User claims nip05 = "alice@example.com" in their kind-0 metadata
2. Verifier fetches: https://example.com/.well-known/nostr.json?name=alice
3. Response must be:
   {
     "names": {
       "alice": "<alice-pubkey-hex>"
     }
   }
4. If the pubkey matches the event's pubkey → verified ✅
```

In mChat this is displayed as a green badge on the contact. Verification happens locally — no central authority.

---

## NIP-28: Group Channels

Group chats use a set of event kinds:

| Kind | Purpose |
|---|---|
| `40` | Create channel — `content` is JSON `{"name":"...", "about":"..."}` |
| `41` | Update channel metadata — replaces kind 40 for the channel ID |
| `42` | Send a message — `tags` must include `["e", "<channel-id>", "", "root"]` |
| `43` | Hide a message (client-side mute) |
| `44` | Mute a user in a channel |

**Channel ID** = event ID of the kind-40 creation event.

```json
// Create a channel
{
  "kind": 40,
  "content": "{\"name\":\"mChat dev\",\"about\":\"Building mChat\"}",
  "tags": [],
  ...
}

// Send a message to the channel
{
  "kind": 42,
  "content": "Hello group!",
  "tags": [["e", "<channel-id>", "wss://relay.url", "root"]],
  ...
}
```

---

## Relay Infrastructure

### Public relays (mChat defaults)

| Relay | Notes |
|---|---|
| `wss://relay.damus.io` | Run by Damus (iOS Nostr client team) |
| `wss://nostr.wine` | Paid relay, spam-filtered |
| `wss://relay.snort.social` | Run by Snort web client team |
| `wss://nos.lol` | Community relay |

### Running your own relay

Self-hosting a relay maximises privacy — the relay operator is *you*.

Popular implementations:
- **nostr-rs-relay** (Rust) — minimal, fast, SQLite storage
- **strfry** (C++) — high performance, supports negentropy sync
- **Nostream** (TypeScript/Node) — feature-rich, PostgreSQL

```bash
# Quick start with nostr-rs-relay (Docker)
docker run -p 8080:8080 scsibug/nostr-rs-relay
```

Connect mChat to your private relay by adding it via the relay management UI (Phase 2).

### NIP-65: Relay List Metadata

Users publish a kind-10002 event listing their preferred relays. Other clients read this to know where to find a user's events and where to send them DMs:

```json
{
  "kind": 10002,
  "tags": [
    ["r", "wss://relay.damus.io"],
    ["r", "wss://my-private-relay.example.com", "write"]
  ]
}
```

---

## Privacy Analysis

### What relay operators can see

| Data | Visibility | Mitigation |
|---|---|---|
| Message content | ❌ Encrypted (NIP-04/44) | — |
| Sender identity | ⚠️ Visible (NIP-04) | NIP-17 Gift Wrap |
| Recipient identity | ⚠️ Visible (both NIPs) | Partial with NIP-17 |
| Message timestamp | ⚠️ Visible | Accept or randomise ±N seconds |
| IP address | ⚠️ Visible | Route via Tor / VPN |
| Message size | ⚠️ Visible (NIP-04) | NIP-44 adds padding |

### Threat model

mChat is designed to protect against:
- **Meta/WhatsApp**: No account, no phone number, no corporate server ✅
- **Relay operator surveillance**: Content protected by E2E encryption ✅ (metadata with NIP-17)
- **Message forgery**: Schnorr signatures make forgery cryptographically impossible ✅
- **Account takeover**: Private key never leaves Keychain ✅
- **Identity linkage**: Pseudonymous by default, bech32 addresses not linked to real identity ✅

mChat does **not** protect against:
- An attacker who compromises your device (private key in Keychain)
- Timing correlation attacks by a relay that observes all traffic
- IP address tracking (use Tor for full protection)

---

## mChat Implementation Map

| NIP | Spec document | mChat file | Status |
|---|---|---|---|
| NIP-01 | Basic protocol, event format | `NostrEvent.swift`, `NostrRelay.swift`, `NostrClient.swift` | ✅ Phase 1 |
| NIP-04 | Encrypted DMs | `NIP04.swift`, `ChatMessage.swift` | ✅ Phase 1 |
| NIP-05 | DNS identity verification | `Contact.swift` (display) | ⚠️ Display only |
| NIP-17 | Gift Wrap / sealed sender | — | 🔜 Phase 2 |
| NIP-19 | Bech32 key encoding (`npub`/`nsec`) | — | 🔜 Phase 2 |
| NIP-28 | Group channels | `NostrBackend.swift` (stub) | 🔜 Phase 2 |
| NIP-44 | Versioned encryption | — | 🔜 Phase 2 |
| NIP-65 | Relay list metadata | — | 🔜 Phase 2 |

---

## Resources

### Specification
- [NIP repository](https://github.com/nostr-protocol/nostr) — all NIPs
- [NIP-01](https://github.com/nostr-protocol/nostr/blob/master/01.md) — Basic Protocol
- [NIP-04](https://github.com/nostr-protocol/nostr/blob/master/04.md) — Encrypted DMs
- [NIP-17](https://github.com/nostr-protocol/nostr/blob/master/17.md) — Gift Wrap
- [NIP-44](https://github.com/nostr-protocol/nostr/blob/master/44.md) — Versioned Encryption
- [NIP-28](https://github.com/nostr-protocol/nostr/blob/master/28.md) — Public Chat

### iOS Clients (for reference)
- [Damus](https://github.com/damus-io/damus) — open source, NIP-04 + NIP-44 DMs
- [Primal](https://github.com/PrimalHQ/primal-ios-app) — open source, caching relay

### Libraries
- [GigaBitcoin/secp256k1.swift](https://github.com/GigaBitcoin/secp256k1.swift) — used in mChat
- [nostr-sdk-ios](https://github.com/nostr-sdk/nostr-sdk-ios) — community iOS SDK

### Tools
- [nostr.watch](https://nostr.watch) — relay browser
- [nostr.band](https://nostr.band) — search and analytics
- [njump.me](https://njump.me) — event / profile web viewer
