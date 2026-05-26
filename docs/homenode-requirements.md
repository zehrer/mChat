# HomeNode – Requirements Document

**Version:** 0.1 (initial)
**Date:** 2026-05-26
**Goal:** A self-hosted personal relay and homeserver, written in Rust, that acts as the private backend for mChat (and other compatible clients).

---

## 1. Vision

HomeNode is a lightweight, privacy-first server you run on your own hardware (Raspberry Pi, VPS, home server). It replaces dependency on third-party relays and commercial homeservers. You own the infrastructure — your messages, your metadata, your rules.

HomeNode complements mChat the same way a personal email server complements a mail client: the client works without it (via public infrastructure), but running your own gives you full control.

---

## 2. Design Principles

| Principle | Detail |
|---|---|
| **Rust-first** | Core implementation in Rust for safety, performance, and low resource usage |
| **Minimal footprint** | Runs on a Raspberry Pi 4 (1 GB RAM, 4-core ARM) |
| **Protocol-agnostic** | Pluggable backend architecture mirrors mChat's `MessagingBackend` pattern |
| **Privacy by default** | No analytics, no telemetry, no cloud calls without explicit configuration |
| **Single binary** | Ships as one statically-linked binary; no runtime dependencies |
| **Self-sovereign** | Works entirely offline / behind NAT; no mandatory registration with any service |

---

## 3. Protocol Backends

HomeNode implements server-side components for the same protocols mChat supports on the client.

### 3.1 Nostr Relay (Phase 1)

| ID | Requirement |
|---|---|
| NR-01 | Implement a NIP-01 compliant Nostr relay over WebSocket (WSS). |
| NR-02 | Support REQ, EVENT, CLOSE, EOSE, OK, and NOTICE message types. |
| NR-03 | Persist events to an embedded SQLite database (via `rusqlite` or `sqlx`). |
| NR-04 | Support NIP-09 event deletion. |
| NR-05 | Support NIP-11 relay information document (JSON metadata endpoint). |
| NR-06 | Support configurable allowed pubkey lists (private relay mode). |
| NR-07 | Support rate limiting per IP and per pubkey. |
| NR-08 | Support TLS termination via `rustls` or reverse-proxy delegation (nginx/caddy). |
| NR-09 | Support NIP-42 authentication for private relay access. |
| NR-10 | The relay shall handle at least 1,000 concurrent WebSocket connections on a Raspberry Pi 4. |

**Rust crates:** `rust-nostr` / `nostr-sdk`, `tokio`, `tokio-tungstenite`, `sqlx` or `rusqlite`, `rustls`

### 3.2 Matrix Homeserver (Phase 2)

Rather than implementing Matrix from scratch, HomeNode embeds or delegates to **Conduit** (a Matrix homeserver written in Rust).

| ID | Requirement |
|---|---|
| MX-01 | Provide a Matrix homeserver conforming to the Matrix Client-Server API (r0.6+). |
| MX-02 | Support federation with other Matrix homeservers (Matrix Server-Server API). |
| MX-03 | Support end-to-end encryption via Olm/Megolm (handled client-side; server stores ciphertext only). |
| MX-04 | Support room creation, invitations, and membership management. |
| MX-05 | Integrate Conduit as an embedded dependency or sidecar process. |
| MX-06 | Share the same SQLite/RocksDB storage backend as the Nostr relay where possible. |
| MX-07 | Expose a single unified configuration file for both Nostr and Matrix. |

**Rust crates:** Conduit (embed or reference), `matrix-rust-sdk` (for client-side testing)

### 3.3 libp2p Node (Phase 3)

| ID | Requirement |
|---|---|
| LP-01 | Run a `rust-libp2p` node for direct P2P routing between mChat clients. |
| LP-02 | Implement Kademlia DHT for peer discovery (fallback when Nostr relays are unavailable). |
| LP-03 | Support mDNS discovery for local network (same Wi-Fi, no internet). |
| LP-04 | Implement GossipSub for group message propagation. |
| LP-05 | Use NOISE protocol (`XX` handshake) for all P2P connections. |
| LP-06 | Expose a relay mode so mChat clients behind NAT can exchange messages via the HomeNode. |

**Rust crates:** `rust-libp2p`, `libp2p-kad`, `libp2p-gossipsub`, `libp2p-noise`, `libp2p-mdns`

---

## 4. Functional Requirements

### 4.1 Administration

| ID | Requirement |
|---|---|
| ADM-01 | Provide a CLI for starting, stopping, and checking status (`homenode start`, `homenode status`). |
| ADM-02 | Provide a web-based admin UI (optional, Phase 2) for relay statistics and configuration. |
| ADM-03 | Expose a health-check endpoint (`GET /health`) returning JSON status. |
| ADM-04 | Log structured JSON to stdout; configurable log level (error/warn/info/debug). |
| ADM-05 | Support configuration via a single TOML file (`homenode.toml`). |
| ADM-06 | Support environment variable overrides for all config values (for Docker/systemd). |

### 4.2 Storage

| ID | Requirement |
|---|---|
| STG-01 | Use an embedded database by default (SQLite via `sqlx`) — no external database required. |
| STG-02 | Support optional PostgreSQL backend for higher-throughput deployments. |
| STG-03 | Implement configurable event retention (e.g. keep last 30 days, max 10 GB). |
| STG-04 | Support automated database backup to a local path or S3-compatible bucket. |
| STG-05 | Events shall survive process restart (no in-memory-only storage). |

### 4.3 Networking

| ID | Requirement |
|---|---|
| NET-01 | Listen on configurable ports for WebSocket (Nostr) and HTTPS (Matrix). |
| NET-02 | Support both IPv4 and IPv6. |
| NET-03 | Support running behind a reverse proxy (strip TLS, trust X-Forwarded-For). |
| NET-04 | Implement connection rate-limiting and automatic IP banning for abuse. |
| NET-05 | Support Let's Encrypt ACME certificate provisioning (optional, via `instant-acme` or similar). |

---

## 5. Non-Functional Requirements

### 5.1 Performance

| ID | Requirement |
|---|---|
| PERF-01 | Handle 1,000 concurrent WebSocket connections on Raspberry Pi 4 (1 GB RAM). |
| PERF-02 | Event storage throughput: ≥ 1,000 events/second on commodity hardware. |
| PERF-03 | Binary startup time: < 500 ms. |
| PERF-04 | Idle memory usage: < 50 MB. |

### 5.2 Security

| ID | Requirement |
|---|---|
| SEC-01 | Verify Schnorr event signatures (secp256k1) before storing any Nostr event. |
| SEC-02 | Validate all incoming JSON strictly; reject malformed events. |
| SEC-03 | Enforce TLS (WSS/HTTPS) for all external connections. |
| SEC-04 | Support IP allowlist/blocklist configuration. |
| SEC-05 | No secrets stored in plaintext; Keychain/secret store for private keys if any. |
| SEC-06 | Dependency audit via `cargo audit` as part of CI. |

### 5.3 Reliability

| ID | Requirement |
|---|---|
| REL-01 | Crash-safe storage: use SQLite WAL mode; no data loss on unclean shutdown. |
| REL-02 | Provide a `systemd` unit file for automatic restart on failure. |
| REL-03 | Provide a Docker image (multi-arch: arm64, amd64). |
| REL-04 | Graceful shutdown: complete in-flight writes before exiting. |

---

## 6. Deployment Targets

| Target | Notes |
|---|---|
| Raspberry Pi 4 / 5 | Primary target; arm64 binary |
| Linux VPS (x86_64) | Secondary target; any Ubuntu/Debian/Alpine |
| Docker | Official multi-arch image on GitHub Container Registry |
| macOS (development) | Build and run locally for development/testing |

---

## 7. Technology Stack

| Component | Choice | Rationale |
|---|---|---|
| Language | Rust (stable) | Safety, performance, single binary, `async`/`await` |
| Async runtime | `tokio` | De-facto standard; excellent WebSocket support |
| WebSocket | `tokio-tungstenite` | Lightweight, tokio-native |
| TLS | `rustls` | Pure Rust, no OpenSSL dependency |
| Nostr protocol | `rust-nostr` / `nostr-sdk` | Official, actively maintained |
| HTTP | `axum` | Ergonomic, tokio-native, tower middleware |
| Database | `sqlx` (SQLite) | Async, compile-time query checking |
| Config | `toml` + `config` crate | Simple, human-editable |
| CLI | `clap` | Standard Rust CLI toolkit |
| Logging | `tracing` + `tracing-subscriber` | Structured, async-aware |
| Matrix | Conduit (embed/sidecar) | Full Matrix homeserver in Rust |
| libp2p | `rust-libp2p` | First-class Rust P2P stack |

---

## 8. Relationship to mChat

```
┌─────────────────────────────┐     ┌────────────────────────────────┐
│  mChat (Swift — iOS/macOS)  │     │  HomeNode (Rust — self-hosted)  │
│                             │     │                                  │
│  NostrPlugin    ────────────┼─WSS─┤  Nostr Relay (NIP-01)          │
│  MatrixPlugin   ────────────┼─HTTPS─  Matrix (Conduit)              │
│  (future)       ────────────┼─P2P─┤  libp2p Node                   │
│                             │     │                                  │
└─────────────────────────────┘     └────────────────────────────────┘
             │                                      │
             └──── both work without the other ─────┘
                   (public relays / matrix.org as fallback)
```

- mChat works without HomeNode (connects to public relays / matrix.org).
- HomeNode works without mChat (any NIP-01 client can connect).
- Together they form a fully self-sovereign messaging stack.

---

## 9. Out of Scope (v1)

- Push notifications (APNs / FCM) — handled client-side
- Web client UI
- Voice/video relay (TURN/STUN server)
- Multi-user / multi-tenant mode (HomeNode is personal, single-owner)
- NIP-65 outbox model relay routing (Phase 2)
- Automated federation with other HomeNode instances

---

## 10. Phased Delivery

### Phase 1 – Nostr Relay
- NIP-01 compliant WebSocket relay
- SQLite-backed event storage
- NIP-11 relay info document
- NIP-42 authentication (private relay)
- Single binary, TOML config, systemd unit, Docker image

### Phase 2 – Matrix Homeserver
- Conduit integration
- Unified config and storage
- Admin web UI (basic)
- Automated TLS (ACME)

### Phase 3 – libp2p Node
- rust-libp2p integration
- Kademlia DHT + mDNS discovery
- GossipSub for group messages
- Relay mode for NAT traversal

---

## 11. Open Questions

| # | Question | Owner |
|---|---|---|
| Q1 | Standalone binary or Cargo workspace shared with mChat? | @zehrer |
| Q2 | Embed Conduit or run as a sidecar process (Docker Compose)? | Engineering |
| Q3 | Should HomeNode support multi-user (family server) or stay strictly single-owner? | @zehrer |
| Q4 | Target Raspberry Pi OS (Debian) or NixOS for the reference deployment? | @zehrer |
| Q5 | Should HomeNode sync events between multiple instances (distributed HomeNodes)? | Research |
