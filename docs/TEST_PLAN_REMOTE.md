# mChatd — Remote Verification Test Plan

Execute all tests by sending DMs from Nostur (or any Nostr client) to the daemon.

**Daemon npub:**
```
npub1xkyup2dgf0zncp9tf88gkl9jy8wpcwtlkluw5saevn34pnza4m7s8m3jpj
```

**Current state before testing:**

| Account | NIP-05 | Role | Access |
|---|---|---|---|
| Main account | stephan@zehrer.net | admin | authorized |
| iPad account | stephan.zehrer@gmail.com | user | authorized |
| Bot | bot@botrift.com | — | blocked |

> Check logs on the server: `tail -f /tmp/mchatd_out.log`

---

## Block 1 — Basic Connectivity

*Send from either account.*

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T01 | `/ping` | `pong` | ☐ |
| T02 | `hello there` | `I can only respond to commands for now. Send /help for the list.` | ☐ |
| T03 | `/echo test message` | `test message` | ☐ |
| T04 | `/echo` | `(empty)` | ☐ |
| T05 | `/unknown` | `Unknown command: /unknown` + hint | ☐ |

---

## Block 2 — Status & Help (send from admin: stephan@zehrer.net)

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T06 | `/status` | Version `mChatd v0.0.2`, uptime, 3 relays, `Authorized: 2 \| Pending: 0 \| Blocked: 1` | ☐ |
| T07 | `/user` | `#1 stephan@zehrer.net [auth][admin]`, `#3 stephan.zehrer@gmail.com [auth][user]`, `#2 bot@botrift.com [blocked]` | ☐ |
| T08 | `/help` | All commands listed, ends with `Your role: admin` | ☐ |

---

## Block 3 — Role Enforcement (send from iPad: stephan.zehrer@gmail.com)

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T09 | `/ping` | `pong` | ☐ |
| T10 | `/help` | All commands listed, ends with `Your role: user` | ☐ |
| T11 | `/user block 2` | `Permission denied: only admins can block users.` | ☐ |
| T12 | `/status` | Status info (updated uptime/count) | ☐ |

---

## Block 4 — Shortcuts (send from either account)

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T13 | `/p` | `pong` | ☐ |
| T14 | `/s` | Same as `/status` | ☐ |
| T15 | `/h` | Same as `/help` | ☐ |
| T16 | `/u` | Same as `/user` list | ☐ |

---

## Block 5 — User Details (send from admin: stephan@zehrer.net)

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T17 | `/user details 1` | Full profile: NIP-05, name, about, website, npub, pubkey | ☐ |
| T18 | `/user det 1` | Same as T17 (shortcut) | ☐ |
| T19 | `/user details 99` | `No user with id #99` | ☐ |

---

## Block 6 — Admin Commands (send from admin: stephan@zehrer.net)

**Authorize / block the bot:**

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T20 | `/user authorize 2` | `#2 bot@botrift.com authorized.` | ☐ |
| T21 | Check: bot receives NIP-17 | `Your access request has been approved! Send /help…` | ☐ |
| T22 | `/user` | Bot shows `[auth][user]` | ☐ |
| T23 | `/user block 2` | `#2 bot@botrift.com blocked.` | ☐ |
| T24 | Check: bot receives NIP-17 | `You have been blocked…` | ☐ |
| T25 | `/user` | Bot shows `[blocked]` | ☐ |

**Shortcut variants:**

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T26 | `/user auth 2` then `/user bl 2` | Same flow as T20–T25 using shortcuts | ☐ |

---

## Block 7 — New User Flow (send from a third Nostr account)

> Use an account that has never messaged the daemon before.

| # | Action | Expected | Pass |
|---|---|---|---|
| T27 | Send any message from new account | Welcome: `Hello! This is mChatd v0.0.2…` | ☐ |
| T28 | Admin receives NIP-17 | `New access request from #<id>…  /user authorize <id> to grant access · /user block <id> to reject` | ☐ |
| T29 | Send second message from same account | `Your access request is still pending authorization.` | ☐ |
| T30 | From admin, `/user` | New account in list with `[pending 2/5]` | ☐ |
| T31 | From admin, `/user authorize <new id>` | `#<id> … authorized.` | ☐ |
| T32 | New account receives NIP-17 | `Your access request has been approved!…` | ☐ |
| T33 | From new account, `/ping` | `pong` | ☐ |

---

## Block 8 — Delete User (send from admin: stephan@zehrer.net)

> Use the newly authorized account from Block 7.

| # | Send | Expected reply | Pass |
|---|---|---|---|
| T34 | `/user del <id from Block 7>` | `#<id> … deleted from all lists.` | ☐ |
| T35 | `/user` | Deleted user no longer appears | ☐ |
| T36 | `/user del 99` | `No user with id #99` | ☐ |
| T37 | `/user delete <id>` as user (non-admin) | `Permission denied: only admins can delete users.` | ☐ |

---

## Block 9 — Relay Backlog / Startup Grace (server-side)

> Requires access to the server.

| # | Action | Expected | Pass |
|---|---|---|---|
| T38 | `make stop` | Daemon terminates | ☐ |
| T39 | From a pending account, send 4 messages while daemon is stopped | No immediate response | ☐ |
| T40 | `make deploy` | Daemon starts, connects to 3 relays | ☐ |
| T41 | Watch log for 15 s | Backlogged messages logged as `[pending N/5][grace]` — no auto-block | ☐ |
| T42 | After grace period, send one more message | `Your access request is still pending authorization.` — count increments | ☐ |

---

## Block 10 — NIP-17 Delivery Verification

| # | Action | Expected | Pass |
|---|---|---|---|
| T43 | Check Nostur for any reply from above tests | Reply appears as NIP-17 (Nostur shows "Increased privacy") | ☐ |
| T44 | Send `/status` twice rapidly | One response per send (deduplication works) | ☐ |

---

## Pass Criteria

| Blocks passed | Status |
|---|---|
| 1–3 | Core functionality verified |
| 1–6 | Commands and role enforcement verified |
| 1–8 | Full user lifecycle verified |
| 1–10 | Full MVP verified |

---

## What to Report

For each failed test:
- Test ID (e.g. T11)
- What you sent
- What you received (or: no response)
- Approximate time (for log correlation)
