# P2P & Decentralised Messaging Technologies

A reference guide for the protocols and stacks considered for mChat and HomeNode.

> **mChat** is the native iOS/macOS client (Swift).
> **HomeNode** is the personal relay/homeserver backend (Rust).
> Both are designed to work together but are independently deployable.

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

**Why we chose it for mChat:** Largest ecosystem, simplest protocol, best iOS tooling, no registration, pseudonymous by default.

**Rust ecosystem:** `rust-nostr` / `nostr-sdk` — comprehensive, actively maintained, first-class support. A personal Nostr relay in Rust is ~500 lines. ✅ Excellent fit for HomeNode.

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
| Rust support | ❌ No official SDK; ecosystem is JS-only |

**How it works:** Hypercore is a distributed, append-only log. Each feed is identified by a public key. Hyperswarm handles NAT traversal and peer discovery via a DHT. Multiple writers are merged with Autobase.

**Keet** is a production P2P video + chat app built on Pear. It demonstrates the protocol's viability for real-time messaging.

**Why not chosen for v1:** The runtime requires Node.js (via Pear runtime), which is a poor fit for a native Swift iOS app. The ecosystem for iOS is nascent. Reconsidering for a future native P2P transport layer.

**Relevant to mChat future:** Could provide a direct device-to-device channel when both users are on the same network or reachable via UDP hole-punching, reducing relay dependency.

**Rust ecosystem:** No official Rust SDK. A community `hypercore` crate exists on crates.io but is incomplete and last active ~2022. No Rust implementation of UDX (Hypercore's custom UDP transport) or Autobase exists. However, the *underlying primitives* map well to Rust:

| Hypercore concept | Rust equivalent |
|---|---|
| Kademlia DHT (Hyperswarm) | `rust-libp2p` kademlia |
| NOISE encryption | `snow` crate (first-class) |
| Append-only log | trivial to implement |
| NAT hole-punching | `rust-libp2p` QUIC / UDP |

**Verdict for HomeNode:** ❌ Not viable today. A Hypercore-inspired design in Rust is possible but requires building the protocol from scratch — cannot interoperate with the existing Pear/Keet ecosystem.

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

**Rust ecosystem:** `matrix-rust-sdk` — the official SDK; Element X on iOS actually uses it via FFI. **Conduit** is a full Matrix homeserver written in Rust — lightweight, self-hostable, actively maintained. ✅ Excellent fit for HomeNode as a personal homeserver.

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

**Rust ecosystem:** `tokio-xmpp` crate exists but is immature and rarely used in production. ⚠️ Weak fit for HomeNode.

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

**Relevance to mChat:** The Double Ratchet provides stronger forward secrecy than NIP-04. A future upgrade could layer Signal Protocol semantics over Nostr transport (some NIPs explore this direction).

**Rust ecosystem:** `libsignal` (Signal's own library) has Rust components. The Double Ratchet is implementable in Rust but there is no standalone "plug-in Signal server" in Rust. ⚠️ Relevant as a crypto primitive, not a standalone backend.

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

**Relevance to mChat:** Could provide direct device-to-device messaging without relays for local network scenarios, or as an alternative P2P transport for a future backend.

**Rust ecosystem:** `rust-libp2p` is one of the *primary* implementations (alongside Go) — used by IPFS, Polkadot, Ethereum 2.0. First-class crate, actively maintained. ✅ Excellent fit for HomeNode as a P2P transport/routing layer.

---

### 7. Veilid

| Property | Value |
|---|---|
| Type | True P2P (DHT-based) |
| Identity | Ed25519 keypair |
| Transport | UDP/TCP with NOISE encryption |
| Data model | DHT-based routing + RPC |
| Maturity | Early production — actively developed by Cult of the Dead Cow |
| iOS support | Limited (Rust FFI bindings) |
| Rust support | ✅ Native Rust — entire stack |

**How it works:** Veilid is a privacy-first P2P network framework. All traffic is routed through the Veilid network using a Kademlia-like DHT. Nodes relay each other's encrypted traffic, similar to Tor but with lower latency.

**Interesting properties:** Designed from the ground up for privacy (no IP leakage by design), works as an application-level overlay network, native Rust implementation.

**Rust ecosystem:** The entire Veilid stack is written in Rust with mobile FFI bindings. ✅ Native Rust — excellent fit for HomeNode, though ecosystem is still small.

---

### 8. Briar

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

**Relevance to mChat:** Inspiration for a future Bluetooth/local-network transport layer. The "works without internet" use case is compelling.

**Rust ecosystem:** Briar is Java/Android. No Rust implementation. ❌ Not applicable for HomeNode.

---

### 9. Secure Scuttlebutt (SSB)

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

**Rust ecosystem:** Community SSB implementations exist in Rust (`kuska-ssb`) but are experimental. ⚠️ Not production-ready for HomeNode.

---

## Rust Ecosystem Summary

This table evaluates each protocol's viability for **HomeNode** — a personal relay/homeserver written in Rust.

| Protocol | Rust crate(s) | Maturity | HomeNode fit | Notes |
|---|---|---|---|---|
| **Nostr** | `rust-nostr`, `nostr-sdk` | ✅ Production | ✅ Excellent | Personal relay in ~500 lines |
| **Matrix** | `matrix-rust-sdk`, Conduit | ✅ Production | ✅ Excellent | Conduit = full homeserver in Rust |
| **libp2p** | `rust-libp2p` | ✅ Production | ✅ Excellent | P2P transport/routing layer |
| **Veilid** | `veilid-core` | ⚠️ Early prod | ✅ Good | Native Rust, small ecosystem |
| **Signal Protocol** | `libsignal` (partial) | ⚠️ Partial | ⚠️ Crypto only | No standalone Rust server |
| **XMPP** | `tokio-xmpp` | ⚠️ Immature | ⚠️ Weak | Crates exist, not production-grade |
| **Pear/Hypercore** | `hypercore` (abandoned) | ❌ Incomplete | ❌ Poor | JS-only ecosystem; no UDX/Autobase in Rust |
| **SimpleX** | — | ❌ None | ❌ Poor | Core stack is Haskell |
| **Briar** | — | ❌ None | ❌ Poor | Java/Android only |
| **SSB** | `kuska-ssb` | ⚠️ Experimental | ⚠️ Weak | Not production-ready |

**Recommended HomeNode starting stack:** Nostr relay (Phase 1) → Matrix/Conduit (Phase 2) → libp2p routing layer (Phase 3).

---

## Comparison Matrix

| Protocol | No server | No phone# | E2E encrypted | iOS (Swift) | Rust backend | Group chat | Offline msgs |
|---|---|---|---|---|---|---|---|
| **Nostr** | Relays (dumb) | ✅ | ✅ NIP-04/44 | ✅ | ✅ | ✅ NIP-28 | ✅ (relay stores) |
| **Matrix** | Self-host | ✅ | ✅ Olm/Megolm | ✅ | ✅ Conduit | ✅ | ✅ |
| **libp2p** | ✅ | ✅ | ✅ | ⚠️ | ✅ | — | — |
| **Veilid** | ✅ | ✅ | ✅ | ⚠️ | ✅ | ⚠️ | ✅ |
| **Pear/Hypercore** | ✅ | ✅ | ✅ | ⚠️ | ❌ | ✅ Autobase | ✅ |
| **XMPP+OMEMO** | Self-host | ✅ | ✅ | ✅ | ⚠️ | ✅ MUC | ✅ |
| **Signal app** | ❌ | ❌ | ✅ | ✅ | ⚠️ | ✅ | ✅ |
| **Briar** | ✅ | ✅ | ✅ | ❌ | ❌ | ⚠️ | ✅ |
| **SSB** | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ⚠️ | ✅ |

---

## mChat + HomeNode Roadmap

```
mChat (Swift — iOS/macOS)          HomeNode (Rust — self-hosted)
─────────────────────────────────  ──────────────────────────────────

Phase 1 (current)
├── Nostr (NIP-01, NIP-04)         ← (public relay network)
└── 1:1 encrypted DMs

Phase 2
├── Nostr NIP-17 (Gift Wrap)       ← HomeNode: personal Nostr relay
├── Nostr NIP-28 (Group channels)     (rust-nostr / nostr-rs-relay)
└── Nostr NIP-44 (XChaCha20)

Phase 3
├── Matrix backend                 ← HomeNode: Conduit homeserver
└── XMPP backend                      (matrix-rust-sdk)

Phase 4 (research)
├── libp2p P2P transport           ← HomeNode: rust-libp2p routing node
├── Veilid overlay routing
└── Briar-inspired Bluetooth mesh
```

The `MessagingBackend` protocol in mChat is designed so each of these can be added as an independent module without changing the UI. HomeNode is the corresponding server-side component — a personal relay and homeserver that you own and operate.

---

## Further Reading

- [Nostr NIPs](https://github.com/nostr-protocol/nostr) — protocol specification
- [Pear / Hypercore](https://docs.pears.com) — Pear runtime and Hypercore docs
- [Matrix Spec](https://spec.matrix.org) — Matrix protocol specification
- [XMPP Standards](https://xmpp.org/extensions/) — XEP extensions including OMEMO
- [Signal Protocol](https://signal.org/docs/) — Double Ratchet and X3DH specs
- [libp2p docs](https://docs.libp2p.io) — modular P2P networking
- [Briar design](https://code.briarproject.org/briar/briar-spec) — Bramble transport spec
