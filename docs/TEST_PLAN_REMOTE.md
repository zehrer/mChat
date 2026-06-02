# mRustChatd — Remote Verification Test Plan

Execute all tests by sending DMs from Nostur (or any Nostr client) to the daemon.

**Daemon npub:**
```
npub1xkyup2dgf0zncp9tf88gkl9jy8wpcwtlkluw5saevn34pnza4m7s8m3jpj
```

**Current state before testing:**

| Account | NIP-05 | Role | Access |
|---|---|---|---|
| Your main account | stephan@zehrer.net | admin | authorized |
| Your iPad account | stephan.zehrer@gmail.com | user | authorized |
| Bot | bot@botrift.com | — | blocked |
| Unknown pending | (no name yet) | — | pending (1/5) |

> Check logs on the server with: `tail -f /tmp/mchatd_out.log`

---

## Block 1 — Basic Connectivity (send from either account)

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T01 | `/ping` | `pong` | ☐ |
| T02 | `hello there` | `echo: hello there` | ☐ |
| T03 | `/echo test message` | `test message` | ☐ |
| T04 | `/echo` | `(empty)` | ☐ |
| T05 | `/unknown` | `Unknown command: /unknown` + hint | ☐ |

---

## Block 2 — Status & User Info (send from admin: stephan@zehrer.net)

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T06 | `/status` | Version, uptime, 3 relays, message count, `Authorized: 2 \| Pending: 1 \| Blocked: 1` | ☐ |
| T07 | `/user` | List showing `#1 stephan@zehrer.net [auth][admin]` and `#3 stephan.zehrer@gmail.com [auth][user]` and `#2 bot@botrift.com [blocked]` and the unknown pending user | ☐ |
| T08 | `/help` | All commands listed, ends with `Your role: admin` | ☐ |

---

## Block 3 — Role Enforcement (send from iPad: stephan.zehrer@gmail.com)

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T09 | `/ping` | `pong` | ☐ |
| T10 | `/help` | All commands listed, ends with `Your role: user` | ☐ |
| T11 | `/block 2` | `Permission denied: only admins can block users.` | ☐ |
| T12 | `/status` | Status info (same as T06 but updated uptime/count) | ☐ |

---

## Block 4 — Admin Commands (send from admin: stephan@zehrer.net)

**T13 — Authorize the pending user:**

The pending user has no display name yet. First send `/user` to confirm their ID, then:

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T13 | `/authorize <id of pending user>` | `#<id> (<pubkey prefix>…) authorized.` | ☐ |
| T14 | `/user` | Pending user now shows `[auth][user]`, no longer in pending | ☐ |

**T15 — Block a user (re-block the bot):**

> The bot (`#2 bot@botrift.com`) is already blocked so first authorize it to test the block flow:

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T15a | `/authorize 2` | `#2 bot@botrift.com authorized.` | ☐ |
| T15b | `/user` | Bot shows `[auth][user]` | ☐ |
| T15c | `/block 2` | `#2 bot@botrift.com blocked.` | ☐ |
| T15d | `/user` | Bot shows `[blocked]` again | ☐ |

---

## Block 5 — New User Flow (send from a third Nostr account you control)

> Use a different Nostr account — one that has never messaged the daemon before.

| # | Action | Expected | Pass |
|---|---|---|---|
| T16 | Send any message from the new account | Welcome message: `Hello! This is mRustChatd v0.0.2. Your contact request has been received…` | ☐ |
| T17 | Send a second message from same account | `Your access request is still pending authorization.` | ☐ |
| T18 | From admin, send `/user` | New account appears in list with `[pending 2/5]` | ☐ |
| T19 | From admin, send `/authorize <new user id>` | New user authorized | ☐ |
| T20 | From new account, send `/ping` | `pong` (now authorized) | ☐ |

---

## Block 6 — Relay Backlog / Startup Grace (server-side test)

> This test requires access to the server logs.

| # | Action | Expected | Pass |
|---|---|---|---|
| T21 | Stop daemon: `make stop` | Process terminates | ☐ |
| T22 | From any pending account, send 4 messages (while daemon is stopped) | No immediate response (daemon offline) | ☐ |
| T23 | Start daemon: `make deploy` | Daemon starts, connects to 3 relays | ☐ |
| T24 | Watch log for 15 s | Backlogged messages logged as `[pending N/5][grace]` — NOT auto-blocked | ☐ |
| T25 | After grace period, send one more message from same account | `Your access request is still pending authorization.` — count increments normally | ☐ |

---

## Block 7 — NIP-17 Delivery Verification

| # | Action | Expected | Pass |
|---|---|---|---|
| T26 | Check Nostur for a reply to any of the above tests | Reply appears as NIP-17 (Nostur shows "Increased privacy" / no NIP-04 warning) | ☐ |
| T27 | Send `/status` twice rapidly | Only one `/status` response per send (deduplication works) | ☐ |

---

## Pass Criteria

| Blocks passed | Status |
|---|---|
| 1–3 | Core functionality verified |
| 1–5 | Access control and role system verified |
| 1–7 | Full MVP verified |

---

## What to Report

For each failed test, note:
- Test ID (e.g. T11)
- What you sent
- What you actually received (or no response)
- Approximate time (so the server log can be correlated)
