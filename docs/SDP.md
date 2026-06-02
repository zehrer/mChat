# Software Development Plan — mChat Daemon Suite

**Version:** 0.2  
**Status:** Active  

---

## 1. Project Overview

mChat is a Nostr-based messaging system consisting of a shared Swift library (**mChatCore**) and two reference daemon implementations — one in Swift (**mSwiftChatd**) and one in Rust (**mChatd**). The daemons act as always-on agents: they receive encrypted DMs, apply access control, respond to commands, and can be extended to run automated tasks.

**Scope of this document:** the two CLI daemons and the mChatCore library.  
**Out of scope:** the iOS/macOS mChat app UI, APNs integration, media handling.

---

## 2. System Architecture

```
~/.mCLIChat/
├── whitelist.txt       # hex pubkeys allowed full access (one per line)
├── blocked.txt         # hex pubkeys permanently ignored
├── pending.json        # {"pubkey": count} — awaiting authorization
├── roles.json          # {"pubkey": "admin"|"user"} — role overrides
├── users.json          # {"pubkey": {id, nip05, name}} — display names
├── config.toml         # [swift] / [rust] name and about strings
├── swift_echo.key      # mSwiftChatd private key (hex)
└── mchatd.key          # mChatd private key (hex)

Sources/
├── mChatCore/          # Swift library: Nostr protocol, crypto, models
│   ├── Nostr/          # NostrClient, NostrRelay, NostrEvent, NostrKeyPair
│   ├── Backend/        # NostrBackend (MessagingBackend implementation)
│   ├── Crypto/         # NIP-04 (AES-CBC), NIP-44 (ChaCha20+HMAC)
│   └── Models/         # ChatMessage, Contact, Conversation
├── mSwiftChatd/        # Swift daemon (uses mChatCore)
│   └── main.swift      # EchoDaemon, UserRegistry, RoleStore, AccessControl
└── mCLIChat/           # Interactive Swift CLI (uses mChatCore)

rust-cli-chat/
└── src/bin/
    └── mChatd.rs   # Rust daemon (standalone, mirrors mSwiftChatd behaviour)
```

**Protocol stack:**

| Layer | Standard | Kind |
|---|---|---|
| DM reception | NIP-17 gift-wrap | 1059 |
| DM reception (legacy) | NIP-04 | 4 |
| DM reply | NIP-17 gift-wrap | 1059 |
| Profile | NIP-01 metadata | 0 |
| Relay list | NIP-65 | 10002 |
| DM relay list | NIP-17 | 10050 |

---

## 3. Development Workflow

### 3.1 Branching Strategy

```
main              ← stable, tagged releases only (no direct commits)
  └── develop     ← integration branch (currently: feature/mCLIChat)
        └── feature/<name>   ← one branch per feature or bug fix
        └── fix/<name>       ← bug fix branches
```

**Rules:**
- Never commit directly to `main`
- Feature branches are created off `develop` and merged back via PR/merge
- `main` is updated only by merging `develop` after verification
- All commits should be self-contained and buildable

### 3.2 Commit Conventions

```
<type>: <short description>

Types: feat | fix | test | docs | refactor | chore
```

Examples: `feat: add /authorize command`, `fix: startup grace period for relay backlog`

### 3.3 Development Cycle

```
1. git checkout -b feature/<name>     # create feature branch
2. <edit code>
3. make test                          # run unit tests — must pass
4. make deploy                        # rebuild release + restart daemons
5. <manual verification — see §6>
6. git commit && git checkout develop && git merge feature/<name>
```

---

## 4. Build System

### 4.1 Prerequisites

| Tool | Install |
|---|---|
| Swift 6.x | `~/.local/share/swiftly/bin/swift` (via swiftly) |
| Rust 1.x + Cargo | `rustup` |
| GNU Make 4.x | system package |

### 4.2 Makefile Target Reference

| Target | Description |
|---|---|
| `make deploy` | **Primary dev loop** — build both release binaries, stop daemons, restart |
| `make test` | Run all unit tests (Swift + Rust) |
| `make test-swift` | Swift unit tests only (`swift test`) |
| `make test-rust` | Rust unit tests only (`cargo test --bin mChatd`) |
| `make test-rust-verbose` | Rust tests with stdout output |
| `make build` | Debug build only (no restart) |
| `make build-release` | Release build only (no restart) |
| `make run-rust-release` | Build Rust release + restart Rust daemon |
| `make run-swift-release` | Build Swift release + restart Swift daemon |
| `make stop` | Kill both running daemons |
| `make status` | Show which daemons are running |
| `make logs` | `tail -f` both log files |
| `make logs-rust` | `tail -f /tmp/mchatd_out.log` |
| `make logs-swift` | `tail -f /tmp/swiftd_out.log` |

### 4.3 Configuration

`~/.mCLIChat/config.toml`:
```toml
[swift]
name  = "mSwiftChatd v0.0.2"
about = "Swift Agent Daemon https://github.com/zehrer/mChat"

[rust]
name  = "mChatd v0.0.2"
about = "Rust Agent Daemon https://github.com/zehrer/mChat"
```

`~/.mCLIChat/roles.json` — set admin rights locally (no command can grant admin):
```json
{
  "YOUR_HEX_PUBKEY": "admin"
}
```

---

## 5. Requirements

### 5.1 Message Reception

| ID | Requirement |
|---|---|
| REQ-01 | NIP-17 gift-wrap messages (kind:1059) are received and decrypted |
| REQ-02 | NIP-04 encrypted DMs (kind:4) are received and decrypted |
| REQ-03 | Messages sent by the daemon itself (`fromMe`) are silently dropped |
| REQ-04 | The same event ID is never processed more than once (deduplication) |

### 5.2 Access Control

| ID | Requirement |
|---|---|
| REQ-10 | A new unknown sender receives a welcome message and is added to `pending` with count=1 |
| REQ-11 | A pending sender's message increments their count and sends a "still pending" reminder |
| REQ-12 | A pending sender who reaches `SPAM_THRESHOLD` (5) is auto-blocked |
| REQ-13 | A blocked sender's messages are silently ignored (no reply) |
| REQ-14 | A whitelisted sender receives command responses |
| REQ-15 | During the startup grace period (15 s), relay-backlogged messages from pending/new senders do not increment spam counters |

### 5.3 Commands

| ID | Requirement |
|---|---|
| REQ-17 | `/ping` → `"pong"` |
| REQ-18 | `/echo <text>` → echoes text; no args → `"(empty)"` |
| REQ-19 | `/status` → version, uptime, relay list, message count, authorized/pending/blocked counts |
| REQ-20 | `/user` → sorted list of senders with ID, access state, role |
| REQ-21 | `/authorize <id>` → moves user from pending/blocked to whitelist, assigns `user` role |
| REQ-22 | `/block <id>` → admin-only; moves user to blocked list |
| REQ-23 | `/block` by a non-admin → permission denied response |
| REQ-24 | `/help` → lists all commands and shows caller's current role |
| REQ-25 | Non-command message from authorized user → `"echo: <text>"` |
| REQ-26 | Unknown command → error message with hint to `/help` |

### 5.4 Roles

| ID | Requirement |
|---|---|
| REQ-27 | Admin role can only be granted locally (editing `roles.json`; no chat command) |
| REQ-28 | `/authorize` assigns `user` role; no entry in `roles.json` defaults to `user` |
| REQ-29 | Admin role can use `/block`; user role cannot |

### 5.5 User Registry

| ID | Requirement |
|---|---|
| REQ-30 | Senders receive sequential integer IDs on first contact |
| REQ-31 | Display name prefers NIP-05 identifier, then `name` field, then truncated pubkey |
| REQ-32 | Metadata is re-fetched from relays if both `nip05` and `name` are empty |

### 5.6 Publishing & Identity

| ID | Requirement |
|---|---|
| REQ-40 | Private key loaded from `*.key` file; generated and saved on first run |
| REQ-41 | kind:0 profile event published on startup with name/about from `config.toml` |
| REQ-42 | NIP-65 relay list (kind:10002) published on startup |
| REQ-43 | NIP-17 DM relay list (kind:10050) published on startup |
| REQ-44 | Replies are sent as NIP-17 gift-wrap (kind:1059) |

### 5.7 Connectivity & Resilience *(future — not yet implemented)*

| ID | Requirement | Status |
|---|---|---|
| REQ-50 | The daemon detects when a relay connection drops and automatically reconnects | TODO |
| REQ-51 | After reconnecting, active subscriptions are re-established without restart | TODO |
| REQ-52 | The daemon detects when the host comes back online after a network outage (e.g. sleep/wake, ISP drop) and reconnects to all configured relays | TODO |
| REQ-53 | On reconnect the startup grace period (REQ-15) is re-applied so relay backlog is not spam-counted | TODO |
| REQ-54 | The admin is notified via DM when the daemon reconnects after an outage longer than a configurable threshold | TODO |

---

## 6. Testing

### 6.1 Unit Tests

Run with `make test`.

**Rust** (`rust-cli-chat/src/bin/mChatd.rs`, `#[cfg(test)]` module):

| Test | Covers |
|---|---|
| `uptime_seconds_only`, `uptime_minutes`, `uptime_hours` | `format_uptime()` edge cases |
| `shorten_64char_hex`, `shorten_short_input_no_panic` | `shorten()` boundary |
| `display_name_prefers_nip05`, `_falls_back_to_name`, `_truncates_pubkey` | REQ-31 |
| `dispatch_plain_text_echoes`, `dispatch_routes_commands` | REQ-25, routing |
| `cmd_ping`, `cmd_echo_with_args`, `cmd_echo_empty` | REQ-17, REQ-18 |
| `cmd_unknown` | REQ-26 |
| `cmd_help_contains_all_commands`, `cmd_help_shows_role` | REQ-24 |
| `cmd_block_requires_admin` | REQ-23, REQ-29 |
| `cmd_block_bad_arg`, `cmd_authorize_bad_arg` | input validation |
| `load_pubkey_file_skips_comments_and_blanks` | file parsing |
| `check_access_new_sender`, `_whitelisted`, `_blocked`, `_pending` | REQ-10–REQ-14 |
| `check_access_whitelist_takes_priority_over_pending` | access priority |
| `get_role_defaults_to_user`, `_admin_from_file` | REQ-27, REQ-28 |
| `ensure_whitelist_creates_file_with_header`, `_is_idempotent` | REQ-40 setup |

**Swift** (`Tests/mChatCoreTests/`):

| File | Covers |
|---|---|
| `NostrKeyPairTests.swift` | REQ-40 — key generation, ECDH |
| `NIP44Tests.swift` | NIP-44 v2 encryption vectors |

**TODO — Swift unit tests to add:**

| Test class | Covers |
|---|---|
| `AccessControlTests` | REQ-10–REQ-15 — access state transitions |
| `RoleStoreTests` | REQ-27, REQ-28 — role persistence and defaults |
| `UserRegistryTests` | REQ-30, REQ-31 — ID assignment, display name priority |
| `DaemonConfigTests` | config.toml parsing, section defaults |
| `CommandDispatchTests` | REQ-17–REQ-26 — all command responses |

To enable these, move `AccessControl`, `RoleStore`, `UserRegistry`, and `DaemonConfig` from `Sources/mSwiftChatd/main.swift` into a new file `Sources/mChatCore/Daemon/DaemonSupport.swift`. They will then be reachable by `mChatCoreTests`.

### 6.2 Manual Verification Plan

For each requirement below, perform the test after `make deploy` and verify against the expected result.

#### V-RECV: Message Reception

| ID | Procedure | Expected |
|---|---|---|
| REQ-01 | Send NIP-17 DM to daemon npub from Nostur | Log shows `[NIP-17][auth]…` and reply received |
| REQ-02 | Send NIP-04 DM via a NIP-04-only client | Log shows `[NIP-04][auth]…` and reply received |
| REQ-03 | Daemon receives its own outgoing gift-wrap | No loop, no self-reply |
| REQ-04 | Relay delivers same event twice | Only one log entry and one reply |

#### V-ACCESS: Access Control

| ID | Procedure | Expected |
|---|---|---|
| REQ-10 | Message from a new (unknown) pubkey | Welcome message received; entry appears in `pending.json` |
| REQ-11 | Second message from same pending pubkey | "Still pending" reply; count incremented |
| REQ-12 | Send 5 messages from a pending pubkey | 5th message triggers auto-block; "blocked" reply sent |
| REQ-13 | Message from a pubkey in `blocked.txt` | No reply; log shows `[blocked]` |
| REQ-14 | Message from a pubkey in `whitelist.txt` | Command response received |
| REQ-15 | Stop daemon, send 6 msgs from new key, restart, wait <15 s, check `pending.json` | Count ≤ 1 (or 0 if messages arrived before daemon fully connected); no auto-block |

#### V-CMD: Commands

| ID | Procedure | Expected |
|---|---|---|
| REQ-17 | Send `/ping` as authorized user | Reply: `pong` |
| REQ-18 | Send `/echo hello` | Reply: `hello` |
| REQ-18 | Send `/echo` (no args) | Reply: `(empty)` |
| REQ-19 | Send `/status` | Reply contains version, uptime, relay count, message count |
| REQ-20 | Send `/user` | Reply lists known senders with `#ID name [auth][role]` |
| REQ-21 | Send `/authorize <id>` as user | Pubkey added to whitelist; `user` role assigned |
| REQ-22 | Send `/block <id>` as admin | Pubkey moved to blocked list |
| REQ-23 | Send `/block <id>` as user | Reply: permission denied |
| REQ-24 | Send `/help` | All commands listed; `Your role: admin/user` shown |
| REQ-25 | Send `hello there` (no `/`) | Reply: `echo: hello there` |
| REQ-26 | Send `/unknown` | Reply: `Unknown command: /unknown` + help hint |

#### V-ROLE: Roles

| ID | Procedure | Expected |
|---|---|---|
| REQ-27 | Edit `roles.json` locally to grant admin; restart; send `/block` | Block succeeds |
| REQ-27 | No entry in `roles.json` for an authorized user | Role defaults to `user` |
| REQ-28 | Run `/authorize <id>`; check `roles.json` | Entry `"user"` appears for that pubkey |
| REQ-29 | Admin sends `/block <id>` | Succeeds |
| REQ-29 | User sends `/block <id>` | Permission denied |

#### V-PUBLISH: Publishing & Identity

| ID | Procedure | Expected |
|---|---|---|
| REQ-40 | Delete `*.key` file; restart | New key generated; pubkey printed to log |
| REQ-40 | Restart with existing key | Same pubkey printed |
| REQ-41 | Check kind:0 on a relay browser after startup | Event with correct name/about |
| REQ-42 | Check kind:10002 on a relay browser | Event with `r`-tagged relay URLs |
| REQ-43 | Check kind:10050 on a relay browser | Event with `relay`-tagged relay URLs |
| REQ-44 | Inspect outgoing reply on relay | Event is kind:1059 (gift-wrap) |

---

## 7. Known Issues / Bug List

| ID | Component | Description | Priority |
|---|---|---|---|
| BUG-01 | mSwiftChatd | Swift daemon receives no messages in current test environment — needs investigation | High |
| BUG-02 | iPad account | `stephan.zehrer@gmail.com` keeps hitting spam threshold on restart due to relay backlog | Medium — mitigated by grace period |
| BUG-03 | mSwiftChatd | No `seen` event-ID deduplication set (REQ-04) | Low |
| BUG-04 | Both | `AccessControl` / access state logic lives in `main.swift`, not in `mChatCore` — untestable by unit tests | Low (tech debt) |

---

## 8. Roadmap

| Milestone | Items |
|---|---|
| v0.0.3 | Move daemon support types to `mChatCore`; add Swift unit tests (BUG-04) |
| v0.0.3 | Fix Swift daemon message reception (BUG-01) |
| v0.1.0 | Auto-reconnect on relay drop + re-subscribe (REQ-50, REQ-51) |
| v0.1.0 | Network outage detection and reconnect with grace period re-apply (REQ-52, REQ-53) |
| v0.1.0 | Admin DM notification on reconnect after outage (REQ-54) |
| v0.1.0 | Periodic relay health check + automatic relay rotation |
| v0.1.0 | Message log to file (`~/.mCLIChat/messages.log`) |
| v0.2.0 | Optional private relay support (NIP-42 auth) |
| v0.2.0 | Multi-agent forwarding: route commands to sub-agents |

---

## 9. Revision History

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-05-xx | Initial draft — access control, commands, roles |
| 0.2 | 2026-06-01 | Add deploy/test make targets; Rust unit tests (29); startup grace period in both daemons; roles system; SDP written |
| 0.3 | 2026-06-01 | Suspend mSwiftChatd; add REQ-50–54 (connectivity resilience, future); remote test plan |
