#!/bin/bash
# Integration test for the termweb tmux shim (Unix socket API).
# Starts termweb mux, exercises all tmux commands via the shim script
# and raw curl, then verifies results.
#
# Usage: ./tests/test-tmux-shim.sh [path-to-binary]
# Exit code: 0 = all passed, 1 = failures

BINARY="${1:-./zig-out/bin/termweb}"
PASS=0
FAIL=0
SKIP=0
TERMWEB_PID=""

# --- helpers ---

cleanup() {
  if [ -n "$TERMWEB_PID" ]; then
    kill "$TERMWEB_PID" 2>/dev/null
    wait "$TERMWEB_PID" 2>/dev/null
  fi
  rm -rf /tmp/termweb-test-stderr.log 2>/dev/null
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  printf "  \033[32mPASS\033[0m %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31mFAIL\033[0m %s  (got: %s)\n" "$1" "$2"
}

skip() {
  SKIP=$((SKIP + 1))
  printf "  \033[33mSKIP\033[0m %s\n" "$1"
}

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$desc"
  else
    fail "$desc" "exit $actual, expected $expected"
  fi
}

assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -qF -- "$expected"; then
    pass "$desc"
  else
    fail "$desc" "'$actual' does not contain '$expected'"
  fi
}

assert_matches() {
  local desc="$1" pattern="$2" actual="$3"
  if echo "$actual" | grep -qE "$pattern"; then
    pass "$desc"
  else
    fail "$desc" "'$actual' does not match /$pattern/"
  fi
}

# --- pre-checks ---

if [ ! -x "$BINARY" ]; then
  echo "Binary not found: $BINARY"
  echo "Run 'zig build' first."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but not found."
  exit 1
fi

# Clean up any stale sockets from previous runs
rm -rf /tmp/termweb-*/ 2>/dev/null

echo "=== Termweb Tmux Shim Integration Tests ==="
echo ""

# --- start server ---

echo "Starting termweb mux..."
"$BINARY" mux --local --port 18199 2>/tmp/termweb-test-stderr.log &
TERMWEB_PID=$!

# Wait for socket to appear (up to 10s)
SOCK=""
for _i in $(seq 1 50); do
  SOCK=$(ls /tmp/termweb-*/tmux.sock 2>/dev/null | head -1)
  if [ -n "$SOCK" ]; then break; fi
  sleep 0.2
done

if [ -z "$SOCK" ]; then
  echo "FATAL: Unix socket did not appear within 10s"
  echo "--- stderr ---"
  cat /tmp/termweb-test-stderr.log 2>/dev/null
  exit 1
fi

SHIM_DIR="$(dirname "$SOCK")/bin"
TMUX_SHIM="$SHIM_DIR/tmux"
echo "Socket: $SOCK"
echo "Shim:   $TMUX_SHIM"
echo ""

# =========================================================
# Test group 1: Shim script basics
# =========================================================
echo "1. Shim script basics"

if [ -x "$TMUX_SHIM" ]; then
  pass "tmux shim is executable"
else
  fail "tmux shim is executable" "not found or not executable"
fi

# =========================================================
# Test group 2: Socket permissions (owner-only)
# =========================================================
echo "2. Socket permissions"

PERMS=$(stat -c '%a' "$SOCK" 2>/dev/null || stat -f '%Lp' "$SOCK" 2>/dev/null || echo "unknown")
if [ "$PERMS" = "700" ]; then
  pass "socket has 700 permissions (owner-only)"
else
  fail "socket permissions" "$PERMS, expected 700"
fi

# =========================================================
# Test group 3: tmux -V
# =========================================================
echo "3. tmux -V"

OUTPUT=$(TERMWEB_SOCK="$SOCK" TERMWEB_PANE_ID=1 "$TMUX_SHIM" -V 2>&1)
assert_contains "returns version string" "termweb-shim" "$OUTPUT"

# =========================================================
# Test group 4: has-session
# =========================================================
echo "4. has-session"

TERMWEB_SOCK="$SOCK" TERMWEB_PANE_ID=1 "$TMUX_SHIM" has-session 2>/dev/null
assert_exit "has-session exits 0" 0 $?

# =========================================================
# Test group 5: list-panes (may be empty)
# =========================================================
echo "5. list-panes"

TERMWEB_SOCK="$SOCK" TERMWEB_PANE_ID=1 "$TMUX_SHIM" list-panes 2>/dev/null
assert_exit "list-panes exits 0" 0 $?

# =========================================================
# Test group 6: display-message
# =========================================================
echo "6. display-message"

OUTPUT=$(TERMWEB_SOCK="$SOCK" TERMWEB_PANE_ID=1 "$TMUX_SHIM" display-message -p '#{pane_id}' 2>/dev/null)
RC=$?
assert_exit "display-message exits 0" 0 $RC
assert_matches "returns pane ID format (%N)" "^%[0-9]+" "$OUTPUT"

# =========================================================
# Test group 7: select-pane (noop, should always succeed)
# =========================================================
echo "7. select-pane"

TERMWEB_SOCK="$SOCK" TERMWEB_PANE_ID=1 "$TMUX_SHIM" select-pane -t %1 2>/dev/null
assert_exit "select-pane exits 0" 0 $?

# =========================================================
# Test group 8: Raw Unix socket — GET endpoints
# =========================================================
echo "8. Raw Unix socket GET"

OUTPUT=$(curl -sf --max-time 3 --unix-socket "$SOCK" \
  "http://localhost/api/tmux?cmd=list-panes" 2>/dev/null)
assert_exit "GET list-panes returns 200" 0 $?

OUTPUT=$(curl -sf --max-time 3 --unix-socket "$SOCK" \
  "http://localhost/api/tmux?cmd=display-message&pane=1&format=%23%7Bpane_id%7D" 2>/dev/null)
RC=$?
assert_exit "GET display-message returns 200" 0 $RC
assert_matches "display-message body has pane_id" "^%[0-9]+" "$OUTPUT"

# =========================================================
# Test group 9: Raw Unix socket — POST endpoints
# =========================================================
echo "9. Raw Unix socket POST"

# send-keys to a non-existent panel → 400 (expected)
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
  --unix-socket "$SOCK" -X POST "http://localhost/api/tmux" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"send-keys","target":999,"keys":"echo test"}' 2>/dev/null || echo "000")
if [ "$HTTP_CODE" != "000" ]; then
  pass "POST endpoint reachable (HTTP $HTTP_CODE)"
else
  fail "POST endpoint reachable" "connection failed"
fi

# split-window — only works if a panel exists (web client connected)
OUTPUT=$(curl -sf --max-time 10 --unix-socket "$SOCK" -X POST "http://localhost/api/tmux" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"split-window","pane":1,"dir":"h"}' 2>/dev/null || echo "")
if [ -n "$OUTPUT" ] && echo "$OUTPUT" | grep -q "pane_id"; then
  pass "POST split-window returns pane_id JSON"

  # Extract new pane ID
  NEW_PANE_ID=$(echo "$OUTPUT" | grep -oP '(?<=pane_id":")[^"]+' | sed 's/^%//')
  if [ -n "$NEW_PANE_ID" ]; then
    pass "split-window created pane %$NEW_PANE_ID"

    # Verify list-panes includes the new pane
    PANES=$(curl -sf --max-time 3 --unix-socket "$SOCK" \
      "http://localhost/api/tmux?cmd=list-panes" 2>/dev/null || echo "")
    if echo "$PANES" | grep -q "%$NEW_PANE_ID"; then
      pass "list-panes includes new pane %$NEW_PANE_ID"
    else
      fail "list-panes includes new pane" "$PANES"
    fi

    # send-keys to the new pane should succeed
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      --unix-socket "$SOCK" -X POST "http://localhost/api/tmux" \
      -H "Content-Type: application/json" \
      -d "{\"cmd\":\"send-keys\",\"target\":$NEW_PANE_ID,\"keys\":\"echo hello\"}" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
      pass "send-keys to new pane returns 200"
    else
      fail "send-keys to new pane" "HTTP $HTTP_CODE"
    fi
  fi
else
  skip "split-window (no initial panel — connect a web client for full test)"
fi

# new-window
OUTPUT=$(curl -sf --max-time 10 --unix-socket "$SOCK" -X POST "http://localhost/api/tmux" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"new-window"}' 2>/dev/null || echo "")
if [ -n "$OUTPUT" ] && echo "$OUTPUT" | grep -q "pane_id"; then
  pass "POST new-window returns pane_id JSON"
else
  skip "new-window (requires panel init — connect a web client for full test)"
fi

# =========================================================
# Test group 10: Shim script content checks
# =========================================================
echo "10. Shim script content"

SCRIPT_CONTENT=$(cat "$TMUX_SHIM")
assert_contains "script reads TERMWEB_SOCK" 'TERMWEB_SOCK' "$SCRIPT_CONTENT"
assert_contains "script reads TERMWEB_PANE_ID" 'TERMWEB_PANE_ID' "$SCRIPT_CONTENT"
assert_contains "script uses --unix-socket" '--unix-socket' "$SCRIPT_CONTENT"
assert_contains "script handles split-window" 'split-window' "$SCRIPT_CONTENT"
assert_contains "script handles send-keys" 'send-keys' "$SCRIPT_CONTENT"
assert_contains "script handles list-panes" 'list-panes' "$SCRIPT_CONTENT"
assert_contains "script handles display-message" 'display-message' "$SCRIPT_CONTENT"
assert_contains "script handles has-session" 'has-session' "$SCRIPT_CONTENT"
assert_contains "script handles new-window" 'new-window' "$SCRIPT_CONTENT"

# --- summary ---

echo ""
TOTAL=$((PASS + FAIL + SKIP))
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32mAll %d tests passed" "$PASS"
  if [ "$SKIP" -gt 0 ]; then
    printf " (%d skipped)" "$SKIP"
  fi
  printf ".\033[0m\n"
  exit 0
else
  printf "\033[31m%d failed, %d passed" "$FAIL" "$PASS"
  if [ "$SKIP" -gt 0 ]; then
    printf ", %d skipped" "$SKIP"
  fi
  printf ".\033[0m\n"
  exit 1
fi
