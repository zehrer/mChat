# Software Development Plan — mChat

**Version:** 0.5
**Status:** Active

---

## 1. Project Overview

mChat is a Nostr-based messaging system with two active components:

- **mChatd** (Rust) — always-on daemon; receives encrypted DMs, applies access control, responds to commands. Target: HomeNode integration.
- **mChat** (iOS, SwiftUI) — native iOS chat app using NostrEssentials as the Nostr protocol layer.
- **mCLIChat** (Rust) — interactive CLI client and integration test tool for mChatd.

The Swift daemon (mSwiftChatd) and the custom Swift Nostr library (mChatCore) are archived in `Archive/`. NostrEssentials (`nostur-com/NostrEssentials`) replaces mChatCore for the iOS app.

---

## 2. System Architecture

```
mChat/
├── Cargo.toml              # Rust workspace [mChatd, mCLIChat]
├── mChatd/                 # Rust daemon
│   └── src/main.rs
├── mCLIChat/               # Rust CLI client / integration test tool
│   └── src/{main,contacts}.rs
├── mChat/                  # iOS app (Xcode project, uses NostrEssentials)
└── Archive/                # mSwiftChatd, mSwiftCLIChat, mChatCore (reference only)
```

**Runtime data** (`~/.mCLIChat/`):

```
~/.mCLIChat/
├── mchatd.key          # mChatd private key (hex)
├── whitelist.txt       # hex pubkeys with full access
├── blocked.txt         # hex pubkeys permanently ignored
├── pending.json        # {"pubkey": count} — awaiting authorization
├── roles.json          # {"pubkey": "admin"|"user"}
├── users.json          # {"pubkey": {id, nip05, name}}
├── last_seen.txt       # high-water timestamp (prevents relay backlog replays)
└── config.toml         # daemon profile name/about
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
main                    ← stable, tagged releases only
  └── feature/mChatd   ← current integration branch
        └── feature/<name>
        └── fix/<name>
```

**Rules:** never commit directly to `main`; merge via PR after verification.

### 3.2 Commit Conventions

```
<type>: <short description>
Types: feat | fix | test | docs | refactor | chore
```

### 3.3 Development Cycle

```
1. git checkout -b feature/<name>
2. <edit code>
3. make test            # 33 unit tests — must all pass
4. make deploy          # rebuild release + restart daemon
5. <verify — see §6>
6. git commit && git push
```

---

## 4. Build System

### 4.1 Prerequisites

| Tool | Install |
|---|---|
| Rust 1.x + Cargo | `rustup` |
| GNU Make 4.x | system package |

### 4.2 Makefile Targets

| Target | Description |
|---|---|
| `make deploy` | Release build + stop + restart mChatd |
| `make test` | `cargo test -p mChatd` (33 unit tests) |
| `make test-verbose` | Tests with stdout output |
| `make build` | Debug build |
| `make build-release` | Release build (no restart) |
| `make stop` | Kill running mChatd |
| `make status` | Show if mChatd is running |
| `make logs` | `tail -f /tmp/mchatd_out.log` |

### 4.3 Configuration

`~/.mCLIChat/config.toml`:
```toml
[rust]
name  = "mChatd v0.0.2"
about = "Rust Agent Daemon https://github.com/zehrer/mChat"
```

`~/.mCLIChat/roles.json` — admin rights (only grantable locally):
```json
{ "YOUR_HEX_PUBKEY": "admin" }
```

---

## 5. Requirements

### 5.1 Message Reception

| ID | Requirement |
|---|---|
| REQ-01 | NIP-17 gift-wrap messages (kind:1059) are received and decrypted |
| REQ-02 | NIP-04 encrypted DMs (kind:4) are received and decrypted |
| REQ-03 | Messages sent by the daemon itself are silently dropped |
| REQ-04 | The same event ID is never processed more than once |
| REQ-05 | `last_seen.txt` high-water mark prevents relay backlog replay on restart |

### 5.2 Access Control

| ID | Requirement |
|---|---|
| REQ-10 | New unknown sender receives a welcome message, added to `pending` with count=1 |
| REQ-11 | Pending sender's message increments count and sends "still pending" reminder |
| REQ-12 | Pending sender reaching `SPAM_THRESHOLD` (5) is auto-blocked |
| REQ-13 | Blocked sender's messages are silently ignored |
| REQ-14 | Whitelisted sender receives command responses |
| REQ-15 | During startup grace period (15 s) relay-backlogged messages from pending/new senders do not increment spam counters |
| REQ-16 | Admins are notified via NIP-17 when a new user requests access |

### 5.3 Commands

| ID | Requirement |
|---|---|
| REQ-17 | `/p(ing)` → `pong` |
| REQ-18 | `/echo <text>` → echoes text; no args → `(empty)` |
| REQ-19 | `/s(tatus)` → version, uptime, relay list, message count, access counts |
| REQ-20 | `/u(ser)` → sorted sender list with ID, access state, role |
| REQ-20a | Corrupt pubkeys shown as `[CORRUPT]` in `/user` list |
| REQ-21 | `/user auth(orize) <id>` → moves to whitelist, assigns `user` role, notifies user |
| REQ-22 | `/user bl(ock) <id>` → admin-only; moves to blocked, notifies user |
| REQ-23 | `/user bl(ock)` by non-admin → permission denied |
| REQ-24 | `/h(elp)` → lists all commands and caller's role |
| REQ-25 | Non-command message → standard reply (`FREE_TEXT_REPLY`) |
| REQ-26 | Unknown command → error + help hint |
| REQ-33 | `/user det(ails) <id>` → full profile re-fetched from relays |
| REQ-34 | `/user del(ete) <id>` → admin-only; removes from all data files |
| REQ-35 | Command shortcuts expand correctly: `/p`→`/ping`, `/s`→`/status`, `/h`→`/help`, `/u`→`/user`, `/user bl`→`/user block`, `/user del`→`/user delete`, `/user det`→`/user details` |

### 5.4 Roles

| ID | Requirement |
|---|---|
| REQ-27 | Admin role can only be granted locally (editing `roles.json`) |
| REQ-28 | `/user authorize` assigns `user` role; missing entry defaults to `user` |
| REQ-29 | Only admins can use `/user block` and `/user delete` |

### 5.5 User Registry

| ID | Requirement |
|---|---|
| REQ-30 | Senders receive sequential integer IDs on first contact |
| REQ-31 | Display name prefers NIP-05, then `name` field, then truncated pubkey |
| REQ-32 | Metadata re-fetched from relays if both `nip05` and `name` are empty |

### 5.6 Publishing & Identity

| ID | Requirement |
|---|---|
| REQ-40 | Private key loaded from `mchatd.key`; generated and saved on first run |
| REQ-41 | kind:0 profile published on startup from `config.toml` |
| REQ-42 | NIP-65 relay list (kind:10002) published on startup |
| REQ-43 | NIP-17 DM relay list (kind:10050) published on startup |
| REQ-44 | Replies sent as NIP-17 gift-wrap (kind:1059) |

### 5.7 Connectivity & Resilience *(future)*

| ID | Requirement | Status |
|---|---|---|
| REQ-50 | Detect relay drop and auto-reconnect | TODO |
| REQ-51 | Re-establish subscriptions after reconnect without restart | TODO |
| REQ-52 | Detect network outage (sleep/wake, ISP drop) and reconnect | TODO |
| REQ-53 | Re-apply startup grace period after reconnect | TODO |
| REQ-54 | Admin DM notification on reconnect after configurable outage threshold | TODO |

---

## 6. Testing

### 6.1 Unit Tests

Run with `make test`. All 33 tests in `mChatd/src/main.rs` (`#[cfg(test)]`):

| Test | Covers |
|---|---|
| `uptime_seconds_only/minutes/hours` | `format_uptime()` |
| `shorten_64char_hex`, `shorten_short_input_no_panic` | `shorten()` |
| `display_name_prefers_nip05`, `_falls_back_to_name`, `_truncates_pubkey` | REQ-31 |
| `dispatch_plain_text_returns_standard_reply` | REQ-25 |
| `dispatch_routes_commands` | command routing |
| `cmd_ping`, `cmd_echo_with_args`, `cmd_echo_empty` | REQ-17, REQ-18 |
| `cmd_unknown` | REQ-26 |
| `cmd_help_contains_all_commands`, `cmd_help_shows_role` | REQ-24 |
| `cmd_user_block_requires_admin` | REQ-23, REQ-29 |
| `cmd_user_block_bad_arg`, `cmd_user_authorize_bad_arg` | input validation |
| `shortcuts_top_level`, `shortcuts_user_subcommands` | REQ-35 |
| `shortcuts_combined_u_plus_subcommand` | REQ-35 chained |
| `shortcuts_no_false_expansion` | REQ-35 safety |
| `load_pubkey_file_skips_comments_and_blanks` | file parsing |
| `check_access_new/whitelisted/blocked/pending` | REQ-10–14 |
| `check_access_whitelist_takes_priority_over_pending` | access priority |
| `get_role_defaults_to_user`, `_admin_from_file` | REQ-27, REQ-28 |
| `ensure_whitelist_creates_file_with_header`, `_is_idempotent` | REQ-40 |

### 6.2 Integration Tests

`mCLIChat --send` drives end-to-end scenarios against a live mChatd. Two test identities (`~/.mCLIChat-test/` admin, `~/.mCLIChat-test2/` user) cover all automated blocks. Run with `make test-integration`.

| Block | Tests | Identity | Covers |
|---|---|---|---|
| 1 | T01–T05 | admin | Basic connectivity (ping, echo, unknown cmd) |
| 2 | T06–T08 | admin | Status, user list, help |
| 3 | T09–T12 | user | Role enforcement (user cannot admin-cmd) |
| 4 | T13–T16 | admin | Command shortcuts |
| 5 | T17–T19 | admin | User details / not-found |
| 6 | T20–T23 | admin | Block → unblock cycle on user identity |
| 7 | T24–T30 | user | New-user welcome → pending → authorize flow |
| 8 | T31–T35 | admin + user | Permission denied, delete user, verify gone, not-found |
| 9–10 | manual | — | HomeNode remote (Block 9), Nostur app (Block 10) |

**No external dependencies:** all 8 automated blocks use the two controlled test identities. The same user identity (`~/.mCLIChat-test2/`) is exercised across Blocks 3, 6, 7, and 8 — role enforcement, state changes, onboarding, and delete.

**Block 7 technique:** delete the user identity from daemon lists → re-contact → daemon treats it as a brand-new unknown user, exercising the full onboarding flow without a separate Nostr account.

**Expected results:**

| Scenario | Pass | Fail | Skip |
|---|---|---|---|
| After ≥ 30 min relay inactivity | 35 | 0 | 2 |
| Shortly after heavy test usage | 33 | 2 (BUG-05) | 2 |

The 2 permanent skips (T25, T29) test NIP-17 admin-notification delivery and require manual inbox verification. The 2 BUG-05 failures appear at **different test positions** in each run — this randomness distinguishes them from code regressions, which would fail the same test every time. See §8 BUG-05.

### 6.3 Manual Verification

See [TEST_PLAN_REMOTE.md](TEST_PLAN_REMOTE.md) for the full remote verification checklist.

---

---

## 7. Code Quality KPIs

Tracked per release. Run locally with `make quality` *(target TBD)*.

| KPI | Tool | Target | Notes |
|---|---|---|---|
| Unit test pass rate | `cargo test -p mChatd` | 100 % | 33 tests; gate for every commit |
| Integration test pass rate | `make test-integration` | 35/35 pass, 2 skip | Target after relay quiet period (≥ 30 min); 33/35 with 2 random failures is acceptable during warm-up — see BUG-05 |
| Compiler warnings | `cargo build` | 0 warnings | `-D warnings` in CI |
| Clippy lints | `cargo clippy` | 0 warnings | `--deny warnings` |
| Unsafe code | `cargo geiger` | 0 unsafe in own crates | Dependencies may use unsafe |
| Dependency freshness | `cargo outdated` | ≤ 3 months behind latest | Review monthly |
| Binary size (release) | `ls -lh target/release/mChatd` | < 10 MB | Log and track per release |
| Test coverage | `cargo llvm-cov` | ≥ 80 % lines mChatd | Backlog — add to CI |

**KIP (Key Inspection Points):**

| KIP | What to verify | When |
|---|---|---|
| KIP-01 Daemon stop | PID file exists; process gone after `make stop`; no zombie | Before every `make deploy` |
| KIP-02 Identity stability | `mchatd.key` unchanged; npub matches expected | After any key/config change |
| KIP-03 Relay connectivity | All 3 relays CONNECTED in startup log | After network change |
| KIP-04 Stale-reply guard | mCLIChat rejects gift wraps older than 120 s | After mCLIChat changes |

---

## 8. Known Issues

| ID | Component | Description | Priority |
|---|---|---|---|
| BUG-02 | mChatd | `stephan.zehrer@gmail.com` hits spam threshold on restart — mitigated by grace period + `last_seen.txt` | Low |
| BUG-05 | Public relays | After ≥ 5 rapid `make test-integration` runs, public relays (nos.lol, relay.damus.io, relay.primal.net) intermittently rate-limit NIP-04 event publishes for up to 45 s. The affected `mCLIChat --send` call times out before the daemon ever receives the command, so no reply arrives. Result: 1–2 random test timeouts per run; exact test varies each run. Retry logic (3× / 1.5 s) handles brief glitches but cannot overcome a sustained rate-limit window. **Recovery:** relay rate limits fully reset after ≥ 30 min of inactivity, returning to 35/35 pass. | Low |

**How to distinguish BUG-05 from a code regression:** a relay rate-limit failure returns an **empty** response (timeout) and the failing test ID differs between runs. A code regression returns a **wrong** response and fails the **same** test every run.

*BUG-01, BUG-03, BUG-04 were mSwiftChatd issues — closed, daemon archived.*

---

## 9. Roadmap

| Milestone | Items |
|---|---|
| v0.0.3 | mCLIChat integration tests (Blocks 1–8 automated) ✓ |
| v0.0.3 | Stale-relay reply guard (120 s timestamp filter in mCLIChat) ✓ |
| v0.0.3 | PID-file based `make stop` (KIP-01) ✓ |
| v0.0.3 | Code quality KPIs + KIP definitions ✓ |
| v0.0.4 | `make quality` target (clippy + warnings + llvm-cov) |
| v0.1.0 | Auto-reconnect on relay drop (REQ-50–54) |
| v0.1.0 | Periodic relay health check + rotation |
| iOS MVP | NostrEssentials integration, NIP-17 1:1 messaging, identity onboarding |
| iOS v1.0 | NIP-44 encryption, NIP-28 group chat, Contacts integration, SwiftData |
| HomeNode | mChatd embedded as agent backend |

---

## 10. Revision History

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-05-xx | Initial draft |
| 0.2 | 2026-06-01 | Rust unit tests (29); startup grace period; roles system |
| 0.3 | 2026-06-01 | Suspend mSwiftChatd; REQ-50–54; remote test plan |
| 0.4 | 2026-06-02 | Restructure to Cargo workspace; archive Swift targets; rename to mChatd; add shortcuts (REQ-35), `/user delete` (REQ-34), `/user details` (REQ-33), admin notifications (REQ-16), last_seen.txt (REQ-05); 33 unit tests |
| 0.5 | 2026-06-03 | mCLIChat integration tests Blocks 1–8 automated (two identities); persisted pre_seen + quiet-period EOSE drain; stale-relay reply guard (120 s); PID-file `make stop` (KIP-01); code quality KPIs + KIP table |
| 0.6 | 2026-06-05 | Document BUG-05 (relay rate-limiting); add CLAUDE.md agent instructions; clarify integration test expected results (35/35 after quiet period, 33/35 during warm-up) |
