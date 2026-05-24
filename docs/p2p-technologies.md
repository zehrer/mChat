# P2P & Decentralised Messaging Technologies

A reference guide for the protocols and stacks considered for mOpenChat.

---

## Why Decentralised Messaging?

Traditional messaging apps (WhatsApp, iMessage, Telegram) rely on a central server operated by a single company. That company can:

- Read metadata (who talks to whom, when, from where)
- Comply with government surveillance requests
- Monetise behavioural data
- Deplatform users unilaterally
- Shut down entirely

Decentralised and P2P approaches distribute trust so that no single entity can do all of the above.

---

## The Spectrum: Federated → P2P

Not all "decentralised" systems are equal. They sit on a spectrum:

```
Centralised          Federated              P2P / Serverless
──────────────────────────────────────────────────────────────
WhatsApp         Matrix / XMPP         Nostr     Briar    Pear
iMessage         Email (SMTP)          SSB       libp2p
Telegram
```

**Federated:** Multiple servers run the same software and exchange messages. No single point of failure but servers still hold data and know identities.

**P2P / relay-based:** Messages route through dumb relays (Nostr) or directly device-to-device (Briar, Pear). The relay or peer sees only encrypted blobs.

---

## Technologies

### 1. Nostr
*Network Of Simple Transferable Records*

| Property | Value |
|---|---|
| Type | Relay-based (quasi-P2P) |
| Identity | secp256k1 keypair (no phone, no email) |
| Transport | WebSocket (WSS) |
| Encryption | NIP-04 (AES-256-CBC) / NIP-44 (XChaCha20) |
| Group chat | NIP-28 channels, NIP-72 communities |
| Maturity | Production — 2+ years, large ecosystem |
| iOS support | Excellent (Damus, Primal, Amethyst) |

**How it works:** Clients broadcast signed JSON events to one or more relays. Relays store and forward events to subscribers. There is no central authority — anyone can run a relay. Messages are signed with the author's private key, making forgery impossible.

**Privacy trade-offs:** NIP-04 hides message *content* but the relay can see sender and recipient pubkeys (metadata). NIP-17 Gift Wrap (sealed sender) solves this.

**Why we chose it for mOpenChat:** Largest ecosystem, simplest protocol, best iOS tooling, no registration, pseudonymous by default.

---

### 2. Pear / Hypercore Protocol
*Formerly the Dat Protocol*

| Property | Value |
|---|---|
| Type | True P2P (DHT-based peer discovery) |
| Identity | Ed25519 keypair |
| Transport | UDP hole-punching via Hyperswarm |
| Data model | Append-only distributed log (Hypercore) |
| Group chat | Autobase (multi-writer merge) |
| Maturity | Production — Keet.io is built on it |
| iOS support | Limited (Node.js runtime required) |

**How it works:** Hypercore is a distributed, append-only log. Each feed is identified by a public key. Hyperswarm handles NAT traversal and peer discovery via a DHT. Multiple writers are merged with Autobase.

**Keet** is a production P2P video + chat app built on Pear. It demonstrates the protocol's viability for real-time messaging.

**Why not chosen for v1:** The runtime requires Node.js (via Pear runtime), which is a poor fit for a native Swift iOS app. The ecosystem for iOS is nascent. Reconsidering for a future native P2P transport layer.

**Relevant to mOpenChat future:** Could provide a direct device-to-device channel when both users are on the same network or reachable via UDP hole-punching, reducing relay dependency.

---

### 3. Matrix / Element

| Property | Value |
|---|---|
| Type | Federated (homeservers) |
| Identity | User ID: `@user:server.org` |
| Transport | HTTPS / WebSocket |
| Encryption | Olm (Double Ratchet) / Megolm (group) |
| Group chat | Rooms (first-class feature) |
| Maturity | Very mature — used by governments, militaries |
| iOS support | Excellent (Element, Beeper) |

**How it works:** Users register on a homeserver (matrix.org or self-hosted). Homeservers federate with each other — like email. The Olm/Megolm cryptographic layer provides E2E encryption at the application level; homeservers see only encrypted ciphertext.

**Strengths:** Best-in-class E2E group encryption (Megolm), verified devices, cross-signing, bridges to other networks (Telegram, WhatsApp, Signal via Beeper).

**Why planned for Phase 3:** Requires a homeserver (can self-host), more complex protocol, but provides the best story for enterprise/group use cases.

---

### 4. XMPP (Extensible Messaging and Presence Protocol)

| Property | Value |
|---|---|
| Type | Federated |
| Identity | JID: `user@server.org` |
| Transport | TCP / WebSocket |
| Encryption | OMEMO (Double Ratchet over XMPP) |
| Group chat | MUC (Multi-User Chat) |
| Maturity | Very mature — RFC standard since 1999 |
| iOS support | Good (Siskin IM, Monal) |

**How it works:** A federated protocol similar to email. Servers exchange messages on behalf of users. OMEMO adds E2E encryption using the Signal Double Ratchet algorithm.

**Strengths:** Extremely mature, widely deployed, open standard, many server implementations (ejabberd, Prosody).

**Weaknesses:** XML-based (verbose), federation reveals metadata to both servers, setup complexity.

---

### 5. Signal Protocol

| Property | Value |
|---|---|
| Type | Encryption layer (not a network protocol) |
| Algorithm | Double Ratchet + X3DH key agreement |
| Used by | Signal, WhatsApp, Google Messages, Wire |
| Forward secrecy | Yes (per-message key rotation) |
| Group | Sender Keys protocol |

**Important distinction:** The Signal *Protocol* (the crypto) is open source and excellent. The Signal *App* requires a phone number and routes through Signal's servers. The protocol can be implemented over any transport.

**Relevance to mOpenChat:** The Double Ratchet provides stronger forward secrecy than NIP-04. A future upgrade could layer Signal Protocol semantics over Nostr transport (some NIPs explore this direction).

---

### 6. libp2p

| Property | Value |
|---|---|
| Type | P2P networking stack (not a messaging protocol) |
| Transports | TCP, QUIC, WebRTC, WebTransport |
| Discovery | DHT (Kademlia), mDNS, bootstrap peers |
| Used by | IPFS, Ethereum, Polkadot, Filecoin |
| iOS support | Go/Rust implementations, Swift bindings limited |

**How it works:** libp2p is a modular networking stack — peer discovery, multiplexing, encryption, and transport are all pluggable. It is the networking layer of IPFS and many blockchain projects.

**Relevance to mOpenChat:** Could provide direct device-to-device messaging without relays for local network scenarios, or as an alternative P2P transport for a future backend.

---

### 7. Briar

| Property | Value |
|---|---|
| Type | True P2P (no servers) |
| Transport | Tor (internet), Bluetooth, WiFi Direct |
| Encryption | Double Ratchet over Bramble protocol |
| Group chat | Forums (store-and-forward) |
| Maturity | Production — Android only |
| iOS support | None |

**How it works:** Briar uses Tor hidden services for internet messaging, Bluetooth for local mesh networking, and WiFi Direct for ad-hoc networks. No server is ever involved.

**Strengths:** Works with no internet connection, extremely censorship-resistant, metadata-resistant via Tor.

**Weaknesses:** Android-only, battery-intensive, slower than relay-based systems, contacts must be added manually via QR code.

**Relevance to mOpenChat:** Inspiration for a future Bluetooth/local-network transport layer. The "works without internet" use case is compelling.

---

### 8. Secure Scuttlebutt (SSB)

| Property | Value |
|---|---|
| Type | P2P gossip protocol |
| Identity | Ed25519 keypair |
| Transport | Gossip (propagates between peers) |
| Storage | Each user has a local append-only log |
| Maturity | Niche but active |
| iOS support | Limited |

**How it works:** Each user has a local, signed append-only feed. Messages gossip from peer to peer. Works offline — messages sync when peers reconnect. "Pubs" (always-on peers) help bridge isolated users.

**Interesting property:** Works well in offline-first / intermittently connected environments.

---

## Comparison Matrix

| Protocol | No server | No phone# | E2E encrypted | iOS | Group chat | Offline msgs |
|---|---|---|---|---|---|---|
| **Nostr** | Relays (dumb) | ✅ | ✅ NIP-04/44 | ✅ | ✅ NIP-28 | ✅ (relay stores) |
| **Pear/Hypercore** | ✅ | ✅ | ✅ | ⚠️ | ✅ Autobase | ✅ |
| **Matrix** | Self-host | ✅ | ✅ Olm/Megolm | ✅ | ✅ | ✅ |
| **XMPP+OMEMO** | Self-host | ✅ | ✅ | ✅ | ✅ MUC | ✅ |
| **Signal app** | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| **Briar** | ✅ | ✅ | ✅ | ❌ | ⚠️ | ✅ |
| **SSB** | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ✅ |
| **libp2p** | ✅ | ✅ | ✅ | ⚠️ | — | — |

---

## mOpenChat Protocol Roadmap

```
Phase 1 (current)
└── Nostr (NIP-01, NIP-04)
    └── 1:1 encrypted DMs via public relay network

Phase 2
├── Nostr NIP-17 (Gift Wrap — sealed sender for metadata privacy)
├── Nostr NIP-28 (Group channels)
└── Nostr NIP-44 (XChaCha20 encryption upgrade)

Phase 3
├── Matrix backend (federated, best for large groups / enterprise)
└── XMPP backend (federated, wide compatibility)

Phase 4 (research)
├── Pear/Hypercore transport (true P2P for local network / offline)
└── Briar-inspired Bluetooth mesh (no internet required)
```

The `MessagingBackend` protocol in mOpenChat is designed so each of these can be added as an independent module without changing the UI.

---

## Further Reading

- [Nostr NIPs](https://github.com/nostr-protocol/nostr) — protocol specification
- [Pear / Hypercore](https://docs.pears.com) — Pear runtime and Hypercore docs
- [Matrix Spec](https://spec.matrix.org) — Matrix protocol specification
- [XMPP Standards](https://xmpp.org/extensions/) — XEP extensions including OMEMO
- [Signal Protocol](https://signal.org/docs/) — Double Ratchet and X3DH specs
- [libp2p docs](https://docs.libp2p.io) — modular P2P networking
- [Briar design](https://code.briarproject.org/briar/briar-spec) — Bramble transport spec
