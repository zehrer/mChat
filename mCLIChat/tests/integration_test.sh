#!/usr/bin/env bash
# mChatd integration test suite
#
# Uses mCLIChat --send to exercise mChatd command-by-command and assert replies.
# Two test identities are used:
#   ~/.mCLIChat-test  — admin identity  (Blocks 1-8)
#   ~/.mCLIChat-test2 — user identity   (Blocks 3, 6, 7, 8)
#
# Block 6 uses the user identity (already authorized) to test admin block/unblock.
# Block 7 (new user flow) deletes the user identity from the daemon, then re-contacts
#   so the daemon treats it as a brand-new unknown user — no external account needed.
# Block 8 uses the re-authorized user identity for delete and permission tests.
#
# Usage:
#   ./integration_test.sh
#
# Environment overrides:
#   DAEMON_NPUB   target daemon npub    (default: hardcoded below)
#   TEST_DIR      admin identity dir    (default: ~/.mCLIChat-test)
#   FRESH_DIR     user identity dir     (default: ~/.mCLIChat-test2)
#   TIMEOUT       reply timeout secs    (default: 30)
#
# Requirements:
#   mChatd must be running  (make status)
#   mCLIChat must be built  (make build or cargo build -p mCLIChat)

set -euo pipefail

DAEMON_NPUB="${DAEMON_NPUB:-npub1xkyup2dgf0zncp9tf88gkl9jy8wpcwtlkluw5saevn34pnza4m7s8m3jpj}"
MCLICHAT_DATA="${HOME}/.mCLIChat"
TEST_DIR="${TEST_DIR:-${HOME}/.mCLIChat-test}"
FRESH_DIR="${FRESH_DIR:-${HOME}/.mCLIChat-test2}"
CLI="$(cd "$(dirname "$0")/../.."; pwd)/target/debug/mCLIChat"
TIMEOUT="${TIMEOUT:-45}"
PASS=0; FAIL=0; SKIP=0
FRESH_PUBKEY=""; FRESH_ID=""; FRESH_NEW_ID=""

# ── Identity setup ────────────────────────────────────────────────────────────

setup_test_identity() {
    mkdir -p "$TEST_DIR"
    TEST_PUBKEY=$(MCLICHAT_DIR="$TEST_DIR" "$CLI" --whoami 2>/dev/null)
    if [ -z "$TEST_PUBKEY" ]; then
        echo "ERROR: could not determine test identity pubkey." >&2; exit 1
    fi
    echo "Test identity (admin): ${TEST_PUBKEY:0:16}…"

    if ! grep -qF "$TEST_PUBKEY" "$MCLICHAT_DATA/whitelist.txt" 2>/dev/null; then
        echo "Registering test identity with daemon (first run)…"
        MCLICHAT_DIR="$TEST_DIR" "$CLI" --send --timeout 20 "$DAEMON_NPUB" "setup" > /dev/null 2>&1 || true
        sleep 2
        echo "Authorizing test identity as admin…"
        echo "$TEST_PUBKEY" >> "$MCLICHAT_DATA/whitelist.txt"
        python3 -c "
import json, os
path = os.path.join('$MCLICHAT_DATA', 'pending.json')
try: p = json.load(open(path))
except: p = {}
p.pop('$TEST_PUBKEY', None)
json.dump(p, open(path, 'w'), indent=2)"
        python3 -c "
import json, os
path = os.path.join('$MCLICHAT_DATA', 'roles.json')
r = json.load(open(path)) if os.path.exists(path) else {}
r['$TEST_PUBKEY'] = 'admin'
json.dump(r, open(path, 'w'), indent=2)"
        echo "Test identity authorized as admin."
    fi
}

# Authorize the user identity as 'user' in daemon files — idempotent.
setup_user_identity() {
    mkdir -p "$FRESH_DIR"
    FRESH_PUBKEY=$(MCLICHAT_DIR="$FRESH_DIR" "$CLI" --whoami 2>/dev/null)
    if [ -z "$FRESH_PUBKEY" ]; then
        echo "ERROR: could not determine fresh identity pubkey." >&2; exit 1
    fi
    echo "Fresh identity (user):  ${FRESH_PUBKEY:0:16}…"

    grep -qF "$FRESH_PUBKEY" "$MCLICHAT_DATA/whitelist.txt" 2>/dev/null || \
        echo "$FRESH_PUBKEY" >> "$MCLICHAT_DATA/whitelist.txt"
    python3 -c "
import json, os
data = '$MCLICHAT_DATA'
ppath = os.path.join(data, 'pending.json')
try: p = json.load(open(ppath))
except: p = {}
p.pop('$FRESH_PUBKEY', None)
json.dump(p, open(ppath, 'w'), indent=2)
rpath = os.path.join(data, 'roles.json')
r = json.load(open(rpath)) if os.path.exists(rpath) else {}
r['$FRESH_PUBKEY'] = 'user'
json.dump(r, open(rpath, 'w'), indent=2)"
    echo "Fresh identity ready (role: user)."
}

# ── Helpers ───────────────────────────────────────────────────────────────────

send()  { MCLICHAT_DIR="$TEST_DIR"  "$CLI" --send --timeout "$TIMEOUT" "$DAEMON_NPUB" "$@" 2>/dev/null; }
send2() { MCLICHAT_DIR="$FRESH_DIR" "$CLI" --send --timeout "$TIMEOUT" "$DAEMON_NPUB" "$@" 2>/dev/null; }

assert_eq() {
    local id="$1" cmd="$2" expected="$3"
    local actual; actual=$(send "$cmd") || true
    if [ "$actual" = "$expected" ]; then
        echo "PASS  $id"; PASS=$((PASS+1))
    else
        echo "FAIL  $id  (sent: $cmd)"
        echo "      expected: $expected"
        echo "      got:      $actual"
        FAIL=$((FAIL+1))
    fi
}

assert_contains() {
    local id="$1" cmd="$2" pattern="$3"
    local actual; actual=$(send "$cmd") || true
    if echo "$actual" | grep -qF "$pattern"; then
        echo "PASS  $id"; PASS=$((PASS+1))
    else
        echo "FAIL  $id  (sent: $cmd)"
        echo "      expected to contain: $pattern"
        echo "      got:      $actual"
        FAIL=$((FAIL+1))
    fi
}

assert_not_contains() {
    local id="$1" cmd="$2" pattern="$3"
    local actual; actual=$(send "$cmd") || true
    if ! echo "$actual" | grep -qF "$pattern"; then
        echo "PASS  $id"; PASS=$((PASS+1))
    else
        echo "FAIL  $id  (sent: $cmd)"
        echo "      expected NOT to contain: $pattern"
        echo "      got:      $actual"
        FAIL=$((FAIL+1))
    fi
}

assert_eq2() {
    local id="$1" cmd="$2" expected="$3"
    local actual; actual=$(send2 "$cmd") || true
    if [ "$actual" = "$expected" ]; then
        echo "PASS  $id"; PASS=$((PASS+1))
    else
        echo "FAIL  $id  (sent as user: $cmd)"
        echo "      expected: $expected"
        echo "      got:      $actual"
        FAIL=$((FAIL+1))
    fi
}

assert_contains2() {
    local id="$1" cmd="$2" pattern="$3"
    local actual; actual=$(send2 "$cmd") || true
    if echo "$actual" | grep -qF "$pattern"; then
        echo "PASS  $id"; PASS=$((PASS+1))
    else
        echo "FAIL  $id  (sent as user: $cmd)"
        echo "      expected to contain: $pattern"
        echo "      got:      $actual"
        FAIL=$((FAIL+1))
    fi
}

skip() { echo "SKIP  $1  ($2)"; SKIP=$((SKIP+1)); }

# ── Run ───────────────────────────────────────────────────────────────────────

echo "mChatd Integration Tests"
echo "Daemon:     $DAEMON_NPUB"
echo "Admin dir:  $TEST_DIR"
echo "User dir:   $FRESH_DIR"
echo ""
setup_test_identity
setup_user_identity
echo ""

echo "=== Block 1: Basic Connectivity ==="
assert_eq        "T01" "/ping"              "pong"
assert_contains  "T02" "hello there"        "I can only respond to commands for now"
assert_eq        "T03" "/echo test message" "test message"
assert_eq        "T04" "/echo"              "(empty)"
assert_contains  "T05" "/unknown"           "Unknown command: /unknown"

echo ""
echo "=== Block 2: Status & Help ==="
assert_contains  "T06a" "/status"  "mChatd v0.0.2"
assert_contains  "T06b" "/status"  "Relays"
assert_contains  "T07"  "/user"    "[auth]"
assert_contains  "T08a" "/help"    "/p(ing)"
assert_contains  "T08b" "/help"    "Your role: admin"

echo ""
echo "=== Block 3: Role Enforcement ==="
assert_eq2       "T09" "/ping"         "pong"
assert_contains2 "T10" "/help"         "Your role: user"
assert_contains2 "T11" "/user block 1" "Permission denied"
assert_contains2 "T12" "/status"       "mChatd v0.0.2"

# Capture the fresh user's current daemon ID (needed for Blocks 6 and 7).
# Users with no NIP-05/name are shown as "#<id> (<first16hex>…)" in /user output.
FRESH_LINE=$(send "/user" | grep "(${FRESH_PUBKEY:0:16}" || true)
FRESH_ID=$(echo "$FRESH_LINE" | grep -oE '#[0-9]+' | tr -d '#' | head -1 || true)

echo ""
echo "=== Block 4: Shortcuts ==="
assert_eq        "T13" "/p"  "pong"
assert_contains  "T14" "/s"  "mChatd v0.0.2"
assert_contains  "T15" "/h"  "/p(ing)"
assert_contains  "T16" "/u"  "[auth]"

echo ""
echo "=== Block 5: User Details ==="
assert_contains  "T17" "/user details 1"   "stephan@zehrer.net"
assert_contains  "T18" "/user det 1"       "stephan@zehrer.net"
assert_contains  "T19" "/user details 99"  "No user with id #99"

echo ""
echo "=== Block 6: Admin State Operations ==="
# The fresh user is in [auth] state. Run a block → unblock cycle to verify admin
# state-change commands. FRESH_ID is left as [auth] so Block 7 can delete it.
if [ -n "${FRESH_ID:-}" ]; then
    assert_contains "T20" "/user block $FRESH_ID"    "blocked"
    assert_contains "T21" "/user"                    "[blocked]"
    assert_contains "T22" "/user authorize $FRESH_ID" "authorized"
    assert_contains "T23" "/user"                    "[auth]"
else
    skip "T20-T23" "fresh identity ID unknown — Block 3 setup may have failed"
fi

echo ""
echo "=== Block 7: New User Flow ==="
# Deleting the fresh identity and re-contacting the daemon replicates the full
# new-user flow without needing a separate Nostr account.
if [ -n "${FRESH_ID:-}" ]; then
    send "/user del $FRESH_ID" > /dev/null

    assert_contains2 "T24" "hello"       "Hello! This is mChatd v0.0.2"
    skip             "T25"               "admin NIP-17 notification — manual check required"
    assert_contains2 "T26" "hello again" "pending authorization"

    # T27: admin sees the fresh user in pending state
    FRESH_NEW_LINE=$(send "/user" | grep "(${FRESH_PUBKEY:0:16}" || true)
    FRESH_NEW_ID=$(echo "$FRESH_NEW_LINE" | grep -oE '#[0-9]+' | tr -d '#' | head -1 || true)
    if echo "$FRESH_NEW_LINE" | grep -qF "[pending"; then
        echo "PASS  T27"; PASS=$((PASS+1))
    else
        echo "FAIL  T27  (/user does not show fresh user as pending)"
        echo "      line: $FRESH_NEW_LINE"
        FAIL=$((FAIL+1))
    fi

    if [ -n "${FRESH_NEW_ID:-}" ]; then
        assert_contains "T28" "/user authorize $FRESH_NEW_ID" "authorized"
        skip            "T29"                                  "approval NIP-17 to new user — manual check required"
        assert_eq2      "T30" "/ping"                          "pong"
    else
        skip "T28-T30" "could not find pending fresh user ID in /user output"
    fi
else
    skip "T24-T30" "fresh identity ID unknown — Block 3 setup may have failed"
fi

echo ""
echo "=== Block 8: Delete & Permissions ==="
# T31: non-admin cannot delete users (fresh identity is now an authorized user)
if [ -n "${FRESH_NEW_ID:-}" ]; then
    assert_contains2 "T31" "/user del 1"              "Permission denied"
    assert_contains  "T32" "/user bl $FRESH_NEW_ID"   "blocked"
    assert_contains  "T33" "/user del $FRESH_NEW_ID"  "deleted from all lists"
    assert_not_contains "T34" "/user"                 "(${FRESH_PUBKEY:0:16}"
else
    skip "T31-T34" "fresh identity not available (Block 7 skipped)"
fi
assert_contains "T35" "/user del 99" "No user with id #99"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════"
printf "Results:  %d passed,  %d failed,  %d skipped\n" "$PASS" "$FAIL" "$SKIP"
echo "════════════════════════════════════════════════"
echo ""
echo "Blocks 9, 10 require manual testing — see docs/TEST_PLAN_REMOTE.md"

# ── Cleanup ───────────────────────────────────────────────────────────────────
# Remove the fresh user identity from the daemon after every run so the user
# list returns to baseline. The test admin identity is kept permanently —
# it is the second stable admin alongside the real admin (stephan@zehrer.net).

echo ""
echo "=== Cleanup ==="

USER_LIST=$(send "/user" 2>/dev/null) || true

# Fresh identity: normally removed in Block 8 (T33), but guard against skips.
CLEANUP_FRESH_LINE=$(echo "$USER_LIST" | grep "(${FRESH_PUBKEY:0:16}" || true)
CLEANUP_FRESH_ID=$(echo "$CLEANUP_FRESH_LINE" | grep -oE '#[0-9]+' | tr -d '#' | head -1 || true)
if [ -n "$CLEANUP_FRESH_ID" ]; then
    send "/user del $CLEANUP_FRESH_ID" > /dev/null || true
    echo "  removed: fresh user #$CLEANUP_FRESH_ID"
else
    echo "  ok: fresh user already removed"
fi

echo ""

[ "$FAIL" -eq 0 ]
