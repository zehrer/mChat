#!/usr/bin/env bash
# mChatd integration test suite
#
# Uses mCLIChat --send to exercise mChatd command-by-command and assert replies.
# A dedicated test identity is auto-created and authorized as admin on first run.
#
# Usage:
#   ./integration_test.sh
#
# Environment overrides:
#   DAEMON_NPUB   target daemon npub   (default: hardcoded below)
#   TEST_DIR      test identity dir    (default: ~/.mCLIChat-test)
#   TIMEOUT       reply timeout secs  (default: 30)
#
# Requirements:
#   mChatd must be running  (make status)
#   mCLIChat must be built  (make build or cargo build -p mCLIChat)

set -euo pipefail

DAEMON_NPUB="${DAEMON_NPUB:-npub1xkyup2dgf0zncp9tf88gkl9jy8wpcwtlkluw5saevn34pnza4m7s8m3jpj}"
MCLICHAT_DATA="${HOME}/.mCLIChat"
TEST_DIR="${TEST_DIR:-${HOME}/.mCLIChat-test}"
CLI="$(cd "$(dirname "$0")/../.."; pwd)/target/debug/mCLIChat"
TIMEOUT="${TIMEOUT:-30}"
PASS=0; FAIL=0; SKIP=0

# ── Test identity setup ───────────────────────────────────────────────────────
#
# mCLIChat supports MCLICHAT_DIR to isolate identity and contacts per directory.
# The test suite uses ~/.mCLIChat-test so it never touches the interactive identity.
# On first run the identity is registered with the daemon and auto-authorized as admin.

setup_test_identity() {
    mkdir -p "$TEST_DIR"

    # Derive pubkey (creates identity.key if it doesn't exist yet)
    TEST_PUBKEY=$(MCLICHAT_DIR="$TEST_DIR" "$CLI" --whoami 2>/dev/null)
    if [ -z "$TEST_PUBKEY" ]; then
        echo "ERROR: could not determine test identity pubkey." >&2; exit 1
    fi
    echo "Test identity: ${TEST_PUBKEY:0:16}…"

    # Register with daemon if not yet known (first-time setup)
    if ! grep -qF "$TEST_PUBKEY" "$MCLICHAT_DATA/whitelist.txt" 2>/dev/null; then
        echo "Registering test identity with daemon (first run)…"
        MCLICHAT_DIR="$TEST_DIR" "$CLI" --send --timeout 20 "$DAEMON_NPUB" "setup" > /dev/null 2>&1 || true
        sleep 2  # allow daemon to write pending.json

        echo "Authorizing test identity as admin…"
        # Add to whitelist
        echo "$TEST_PUBKEY" >> "$MCLICHAT_DATA/whitelist.txt"
        # Remove from pending
        python3 -c "
import json, sys, os
path = os.path.join('$MCLICHAT_DATA', 'pending.json')
try: p = json.load(open(path))
except: p = {}
p.pop('$TEST_PUBKEY', None)
json.dump(p, open(path, 'w'), indent=2)"
        # Set admin role
        python3 -c "
import json, sys, os
path = os.path.join('$MCLICHAT_DATA', 'roles.json')
r = json.load(open(path)) if os.path.exists(path) else {}
r['$TEST_PUBKEY'] = 'admin'
json.dump(r, open(path, 'w'), indent=2)"
        echo "Test identity authorized as admin."
    fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

send() { MCLICHAT_DIR="$TEST_DIR" "$CLI" --send --timeout "$TIMEOUT" "$DAEMON_NPUB" "$@" 2>/dev/null; }

assert_eq() {
    local id="$1" cmd="$2" expected="$3"
    local actual; actual=$(send "$cmd")
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
    local actual; actual=$(send "$cmd")
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
    local actual; actual=$(send "$cmd")
    if ! echo "$actual" | grep -qF "$pattern"; then
        echo "PASS  $id"; PASS=$((PASS+1))
    else
        echo "FAIL  $id  (sent: $cmd)"
        echo "      expected NOT to contain: $pattern"
        echo "      got:      $actual"
        FAIL=$((FAIL+1))
    fi
}

skip() { echo "SKIP  $1  ($2)"; SKIP=$((SKIP+1)); }

# ── Run ───────────────────────────────────────────────────────────────────────

echo "mChatd Integration Tests"
echo "Daemon:     $DAEMON_NPUB"
echo "Test dir:   $TEST_DIR"
echo ""
setup_test_identity
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
echo "=== Block 6: Admin Commands ==="
# Find bot ID dynamically (it may have changed after delete/re-register cycles)
BOT_LINE=$(send "/user" | grep "bot@botrift.com" || true)
BOT_ID=$(echo "$BOT_LINE" | grep -oE '#[0-9]+' | tr -d '#' | head -1 || true)
if [ -z "$BOT_ID" ]; then
    skip "T20-T26" "bot@botrift.com not found in /user list — re-run after bot re-registers"
else
    assert_contains  "T20" "/user authorize $BOT_ID"  "authorized"
    assert_contains  "T22" "/user"                    "[auth]"
    assert_contains  "T23" "/user block $BOT_ID"      "blocked"
    assert_contains  "T25" "/user"                    "[blocked]"
    assert_contains  "T26a" "/user auth $BOT_ID"      "authorized"
    assert_contains  "T26b" "/user bl $BOT_ID"        "blocked"
fi

echo ""
echo "=== Block 8: Delete ==="
# Re-authorize bot to test delete
if [ -n "${BOT_ID:-}" ]; then
    send "/user auth $BOT_ID" > /dev/null
    assert_contains     "T34" "/user del $BOT_ID"  "deleted from all lists"
    assert_not_contains "T35" "/user"               "bot@botrift.com"
    echo "INFO  bot deleted — it will reappear when it next contacts the daemon"
else
    skip "T34-T35" "bot ID unknown, skipping delete test"
fi
assert_contains  "T36" "/user del 99"  "No user with id #99"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════"
printf "Results:  %d passed,  %d failed,  %d skipped\n" "$PASS" "$FAIL" "$SKIP"
echo "════════════════════════════════════════════════"
echo ""
echo "Blocks 3, 7, 9, 10 require manual testing — see docs/TEST_PLAN_REMOTE.md"
echo ""

[ "$FAIL" -eq 0 ]
