# mCLIChat Integration Tests

Automated end-to-end test suite for mChatd. Uses `mCLIChat --send` to send
commands to a live daemon and assert the replies — no mocking, real relay traffic.

---

## How it works

`integration_test.sh` uses a **dedicated test identity** isolated in
`~/.mCLIChat-test/` (separate from your interactive CLI identity). On first run
it registers that identity with the daemon and auto-authorizes it as admin.

Each test:
1. Calls `mCLIChat --send <daemon-npub> <command>`
2. Waits up to 30 s for a reply (configurable via `TIMEOUT`)
3. Asserts the reply equals or contains the expected string

---

## Running

```bash
# Prerequisites: mChatd running, mCLIChat built
make status          # verify daemon is up
make build           # build mCLIChat debug binary

# Run integration tests
make test-integration

# Or directly:
bash mCLIChat/tests/integration_test.sh
```

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DAEMON_NPUB` | hardcoded in script | Target daemon npub |
| `TEST_DIR` | `~/.mCLIChat-test` | Test identity directory |
| `TIMEOUT` | `30` | Reply timeout in seconds |

---

## Multiple identities

`mCLIChat` uses `MCLICHAT_DIR` to select which identity directory to use:

```bash
# Interactive CLI — uses ~/.mCLIChat/identity.key
mCLIChat

# Admin test client — uses ~/.mCLIChat-test/identity.key
MCLICHAT_DIR=~/.mCLIChat-test mCLIChat

# User test client — uses ~/.mCLIChat-test2/identity.key
MCLICHAT_DIR=~/.mCLIChat-test2 mCLIChat

# One-off send as test identity
MCLICHAT_DIR=~/.mCLIChat-test mCLIChat --send <npub> "/ping"

# Print pubkey of any identity
MCLICHAT_DIR=~/.mCLIChat-test mCLIChat --whoami
```

---

## Test coverage

| Block | Tests | Identity | Coverage |
|---|---|---|---|
| 1 — Basic Connectivity | T01–T05 | admin | `/ping`, free-text reply, `/echo`, unknown command |
| 2 — Status & Help | T06–T08 | admin | `/status`, `/user`, `/help` + role |
| 3 — Role Enforcement | T09–T12 | user | permission denied on admin commands |
| 4 — Shortcuts | T13–T16 | admin | `/p`, `/s`, `/h`, `/u` |
| 5 — User Details | T17–T19 | admin | `/user det`, not-found |
| 6 — Admin Commands | T20–T26 | admin | authorize, block, shortcut variants |
| 7 — New User Flow | T27–T33 | user (deleted+re-registered) | welcome, pending, authorize, ping |
| 8 — Delete | T34–T37 | admin + user | `/user del`, not-found, permission denied |

**Automated:** Blocks 1–8

**Skipped within Block 7** (NIP-17 inbox checks — require a Nostr client):
- T28 — admin receives new-user notification
- T32 — new user receives approval message

**Manual only** (require server access or a Nostr client):
- Block 9 — Relay backlog / startup grace period
- Block 10 — NIP-17 delivery verification in Nostur

### How Block 7 works without a fresh device

Deleting a user from the daemon removes them from all lists. When they next send
a message the daemon treats them as unknown and runs the full new-user flow.
The test suite deletes the user identity (`~/.mCLIChat-test2/`) at the start of
Block 7 and re-contacts the daemon, then verifies welcome → pending → authorize →
ping without needing a separate Nostr account.

See [docs/TEST_PLAN_REMOTE.md](../../docs/TEST_PLAN_REMOTE.md) for the full manual checklist.

---

## Adding tests

Add `assert_eq` / `assert_contains` / `assert_not_contains` calls to
`integration_test.sh`. Each assertion sends one command and checks the reply:

```bash
assert_eq       "T99" "/ping"          "pong"
assert_contains "T99" "/status"        "mChatd v0.0.2"
assert_not_contains "T99" "/user"      "deleted_user"
```

For tests that need a fresh/unknown identity (Block 7 new-user flow), create
a second test directory:

```bash
FRESH_DIR=$(mktemp -d)
MCLICHAT_DIR="$FRESH_DIR" "$CLI" --send "$DAEMON_NPUB" "hello"
```
