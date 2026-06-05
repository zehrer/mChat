# CLAUDE.md — mChat Agent Instructions

Instructions for Claude agents working in this repository.

---

## Project context

mChat is a Nostr-based messaging system. Active components:

- **mChatd** (`mChatd/src/main.rs`) — Rust daemon; receives NIP-17/NIP-04 DMs, applies access control, responds to commands
- **mCLIChat** (`mCLIChat/src/main.rs`) — Rust CLI client; `--send` mode drives the integration test suite
- **mChat** (`mChat/`) — iOS app (SwiftUI + NostrEssentials); out of scope for Rust work
- **Archive/** — retired Swift daemon and CLI; reference only, do not modify

Full architecture, requirements, and workflow in `docs/SDP.md`.

---

## Workflow

1. Branch from `feature/mChatd` (never commit directly to `main`)
2. `make test` — all 33 unit tests must pass before every commit
3. `make deploy` — rebuild release binary and restart the daemon
4. `make test-integration` — run end-to-end tests (see §Interpreting test results below)
5. Commit and push after every successful build (no confirmation needed)

---

## Interpreting integration test results

Run with `make test-integration`. The suite has 35 automated tests + 2 permanent skips.

### Normal (clean) result

```
Results:  35 passed,  0 failed,  2 skipped
```

Achievable after ≥ 30 min of relay inactivity.

### Acceptable warm-up result (BUG-05)

```
Results:  33 passed,  2 failed,  2 skipped
```

This is **not a code regression**. It is caused by public relay rate-limiting (BUG-05 in `docs/SDP.md`).

**How to tell the difference:**

| Symptom | Relay rate-limit (BUG-05) | Code regression |
|---|---|---|
| Failing test response | Empty (timeout after 45 s) | Wrong text returned |
| Failing test IDs | Different each run | Same test fails every run |
| Number of failures | 1–2 | Consistent across runs |

**Rule:** if the failing tests return empty responses **and** the failing test IDs differ between two consecutive runs, it is BUG-05 — proceed with the PR/merge.

If any test returns the **wrong content** (not empty), or the **same test** fails in multiple consecutive runs, that is a code regression — investigate before merging.

### Permanent skips

T25 and T29 are always skipped — they test NIP-17 admin-notification delivery and require manual inbox verification. Two skips is correct.

### Recovery from rate-limiting

Wait ≥ 30 min without running `make test-integration`, then re-run. Rate limits reset per key and per IP on nos.lol, relay.damus.io, and relay.primal.net.

---

## Daemon key

The daemon npub is `npub1xkyup2dgf0zncp9tf88gkl9jy8wpcwtlkluw5saevn34pnza4m7s8m3jpj`.  
Private key lives in `~/.mCLIChat/mchatd.key`. Never commit or log the private key.

---

## Data files

All runtime state is in `~/.mCLIChat/`. Do not commit these files. Key files:

The daemon profile name is always taken from the `VERSION` constant in code — `config.toml` only needs an `about` field.

| File | Purpose |
|---|---|
| `whitelist.txt` | Hex pubkeys with full access |
| `blocked.txt` | Hex pubkeys permanently ignored |
| `pending.json` | `{pubkey: count}` — awaiting authorization |
| `roles.json` | `{pubkey: "admin"\|"user"}` |
| `users.json` | `{pubkey: {id, nip05, name}}` — display registry |
| `last_seen.txt` | High-water timestamp — prevents relay backlog replay on restart |

When writing test setup/cleanup code, always handle **all five** of `whitelist.txt`, `blocked.txt`, `pending.json`, `roles.json`, and `users.json`. Omitting `blocked.txt` can leave test identities blocked across runs.

---

## Key invariants

- `last_seen_ts` guard uses `<` (not `<=`): two commands in the same Unix second must both be processed; exact deduplication is handled by the `seen: HashSet<EventId>` in memory.
- NIP-04 subscription carries `.since(last_seen_ts)` so the relay does not replay old messages on restart. NIP-17 (GiftWrap) has **no** `since` filter because outer timestamps are randomized per NIP-59.
- Admin role can only be granted by editing `roles.json` locally — never via relay command.
- `make stop` uses `pkill -x mChatd` unconditionally. Never revert to PID-file-only stop.
