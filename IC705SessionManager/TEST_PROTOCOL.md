# IC-705 Session Manager Test Protocol

## Overview

This document describes the manual testing protocol for validating the IC705SessionManager library and CLI tool. These tests verify that the new state machine-based architecture correctly handles the UI workflows before integration into the main React Native app.

## Prerequisites

- IC-705 radio powered on and connected to the same network
- Radio's IP address (typically 192.168.x.x from WiFi status)
- RS-BA1 credentials (default: user=ADMIN, password=ADMIN)
- CLI tool built: `swift build` in `IC705SessionManager/` directory

## Test Environment Setup

```bash
# Build the CLI tool
cd IC705SessionManager
swift build

# Create an alias for convenience
alias ic705='.build/debug/ic705-cli'

# Verify it works
ic705 --help
```

---

## Test 1: Basic Connect → Query → Disconnect

**Purpose**: Verify basic connection lifecycle works correctly.

**Steps**:
```bash
# 1. Connect with verbose output
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN --verbose

# Expected output:
# Connecting to 192.168.2.144...
#   [UDP ready on port 50001]
#   [Received IAmHere on port 50001]
#   [Sending AreYouReady on port 50001]
#   [Control socket ready; sending login]
#   [Login accepted; token received]
#   [Sending token acknowledge]
#   [Capabilities received from IC-705]
#   [Sending ConnInfo with local CI-V port 50002]
#   [Control status received; remote CI-V port 50002]
#   [Opening CI-V stream...]
#   [Serial socket ready; sending OpenClose]
# Connected to IC-705

# 2. Query status
ic705 status

# Expected output:
# Frequency: 14.060 MHz
# Mode: CW

# 3. Query with JSON output
ic705 status --json

# Expected output:
# {
#   "frequencyHz" : 14060000,
#   "mode" : "CW",
#   "isConnected" : true
# }

# 4. Disconnect
ic705 disconnect --verbose

# Expected output:
#   [Disconnecting...]
# Disconnected
```

**Pass Criteria**:
- [ ] Connect completes without errors
- [ ] Status query returns valid frequency and mode
- [ ] JSON output is valid and parseable
- [ ] Disconnect completes cleanly
- [ ] Radio shows no error indicators

---

## Test 2: Rapid Query Test

**Purpose**: Simulates QSO page focus changes that trigger repeated status queries.

**Steps**:
```bash
# 1. Connect first
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN

# 2. Run rapid queries
for i in {1..20}; do
    echo "Query $i:"
    ic705 status
    sleep 0.5
done

# 3. Disconnect
ic705 disconnect
```

**Pass Criteria**:
- [ ] All 20 queries succeed
- [ ] No "radio busy" errors
- [ ] No crashes or hangs
- [ ] Frequency/mode values are consistent (minor VFO tuning allowed)

**Stress Test** (optional):
```bash
# Run queries as fast as possible
for i in {1..50}; do ic705 status; done
```

---

## Test 3: CW During Query

**Purpose**: Verifies that CW sending properly serializes with status queries and doesn't crash.

**Steps**:
```bash
# 1. Connect
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN

# 2. In Terminal 1: Start a background status query loop
while true; do ic705 status; sleep 2; done &
QUERY_PID=$!

# 3. In Terminal 1: Send CW while queries are running
sleep 1
ic705 send-cw "TEST"
sleep 1
ic705 send-cw "DE W1AW"
sleep 1
ic705 send-cw "K"

# 4. Stop the background loop
kill $QUERY_PID

# 5. Verify radio is still responsive
ic705 status

# 6. Disconnect
ic705 disconnect
```

**Alternative (Single Terminal)**:
```bash
# Connect
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN

# Send multiple CW commands in sequence
ic705 send-cw "CQ CQ"
ic705 send-cw "DE W1AW"
ic705 send-cw "K"

# Check status between sends
ic705 status

# Disconnect
ic705 disconnect
```

**Pass Criteria**:
- [ ] CW sends successfully
- [ ] Status queries continue to work
- [ ] No race condition errors
- [ ] Radio remains connected throughout

---

## Test 4: Connection Recovery

**Purpose**: Verify graceful handling of network disruptions.

**Steps**:
```bash
# 1. Connect
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN --verbose

# 2. Start watch mode in background
ic705 watch &
WATCH_PID=$!
sleep 5

# 3. Physically disrupt connection (choose one):
#    a) Turn off radio WiFi temporarily
#    b) Disconnect from WiFi network for 5 seconds
#    c) Move out of WiFi range

# 4. Wait 10 seconds, then restore connection

# 5. Stop watch mode
kill $WATCH_PID 2>/dev/null

# 6. Try to reconnect
ic705 disconnect  # Clean up any stale state
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN
ic705 status
ic705 disconnect
```

**Pass Criteria**:
- [ ] Initial connection succeeds
- [ ] Clear error message when connection lost
- [ ] Clean disconnect succeeds even in error state
- [ ] Reconnection succeeds after network restored
- [ ] No zombie processes or resource leaks

---

## Test 5: Concurrent Client Test

**Purpose**: Verify radio single-client enforcement and proper error handling.

**Setup**: Open two terminal windows.

**Terminal 1**:
```bash
# Connect first client
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN --verbose
# Leave connected
```

**Terminal 2**:
```bash
# Try to connect second client
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN --verbose

# Expected: Should either:
#   a) Fail with "radio busy" or authentication error, OR
#   b) Steal connection (first client gets disconnected)

# If steal occurs:
ic705 status  # Should work

# Disconnect
ic705 disconnect
```

**Back in Terminal 1**:
```bash
# Check if still connected
ic705 status

# If disconnected, should get error
```

**Pass Criteria**:
- [ ] Second connection attempt gets clear error or steals connection
- [ ] No crashes on either client
- [ ] First client receives disconnect notification (if stolen)
- [ ] Radio remains accessible after test

---

## Test 6: Session Persistence

**Purpose**: Verify saved sessions work correctly.

**Steps**:
```bash
# 1. Connect and save session
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN --save --verbose

# Expected output includes:
# Session saved to /Users/<user>/.config/ic705/ic705-session.json

# 2. Disconnect
ic705 disconnect

# 3. Use saved session (no credentials needed)
ic705 status --verbose

# Expected: Auto-connects using saved session

# 4. Disconnect and clear
ic705 disconnect --clear --verbose

# 5. Try to use cleared session
ic705 status

# Expected: Error - "Not connected and no saved session found"
```

**Pass Criteria**:
- [ ] Session saves correctly
- [ ] Auto-connect works with saved session
- [ ] Clear removes saved session
- [ ] Clear fails gracefully when no session exists

---

## Test 7: CW Edge Cases

**Purpose**: Verify CW sending handles edge cases correctly.

**Steps**:
```bash
# 1. Connect
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN

# 2. Test empty text (should fail gracefully)
ic705 send-cw "" 2>&1

# Expected: Error about empty text

# 3. Test too long text (should fail)
ic705 send-cw "THIS TEXT IS WAY TOO LONG FOR THE CW BUFFER IT SHOULD FAIL"

# Expected: Error about text length

# 4. Test valid text at length limit (30 chars)
ic705 send-cw "CQ CQ DE W1AW K 599 599"

# Expected: Success

# 5. Test with special characters (should uppercase)
ic705 send-cw "test lower case"

# Expected: Sends as "TEST LOWER CASE"

# 6. Disconnect
ic705 disconnect
```

**Pass Criteria**:
- [ ] Empty text fails gracefully with clear error
- [ ] Text > 30 chars fails gracefully
- [ ] Valid text sends successfully
- [ ] Lowercase text is uppercased

---

## Test 8: Watch Mode

**Purpose**: Verify continuous monitoring works correctly.

**Steps**:
```bash
# 1. Connect
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN

# 2. Start watch mode (run for 10 seconds then Ctrl+C)
timeout 10 ic705 watch

# Expected: Continuously updating display like:
# 14.060 MHz | CW

# 3. Watch with JSON output
timeout 5 ic705 watch --json

# Expected: Stream of JSON objects

# 4. Watch with custom interval
timeout 5 ic705 watch --interval 2.0

# Expected: Updates every 2 seconds

# 5. Disconnect
ic705 disconnect
```

**Pass Criteria**:
- [ ] Watch mode displays frequency/mode
- [ ] Ctrl+C stops gracefully
- [ ] JSON mode outputs valid JSON
- [ ] Custom interval is respected

---

## Test 9: Error Handling

**Purpose**: Verify error messages are clear and helpful.

**Steps**:
```bash
# 1. Try to connect with wrong IP
ic705 connect --host 192.168.255.255 --user ADMIN --pass ADMIN

# Expected: Timeout error

# 2. Try to connect with wrong credentials
ic705 connect --host 192.168.2.144 --user WRONG --pass WRONG

# Expected: Authentication failure

# 3. Try operations without connecting
ic705 disconnect  # Should succeed (idempotent)
ic705 status      # Should fail with "not connected"

# 4. Try send-cw without connecting
ic705 send-cw "TEST"

# Expected: "Not connected and no saved session found"
```

**Pass Criteria**:
- [ ] Wrong IP: Clear timeout message
- [ ] Wrong credentials: Clear auth failure
- [ ] Not connected: Clear "not connected" error
- [ ] Disconnect when not connected: Succeeds (idempotent)

---

## Test 10: State Machine Validation

**Purpose**: Verify state transitions work correctly.

**Steps**:
```bash
# 1. Try to connect when already connected
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN 2>&1

# Expected: "Already connected to radio"

# 2. Try operations during state transitions
# (This is a timing test - run connect and immediately try status)
ic705 connect --host 192.168.2.144 --user ADMIN --pass ADMIN &
sleep 0.5
ic705 status 2>&1
wait

# 3. Disconnect twice (idempotent)
ic705 disconnect
ic705 disconnect

# Expected: Both succeed, no error

# 4. Try to disconnect when not connected
ic705 disconnect

# Expected: Succeeds silently
```

**Pass Criteria**:
- [ ] Double connect: Clear "already connected" error
- [ ] Operations during transitions: Handled gracefully
- [ ] Double disconnect: Both succeed
- [ ] Disconnect when not connected: Succeeds

---

## Regression Checklist

Before declaring Phase 4 complete, verify:

- [ ] All 10 tests above pass
- [ ] No memory leaks (monitor with Activity Monitor during long watch test)
- [ ] Radio remains stable after all tests (no lockups requiring power cycle)
- [ ] CLI tool exits cleanly in all scenarios (check with `echo $?`)

---

## Test Log Template

```markdown
## Test Run: YYYY-MM-DD

### Environment
- Radio: IC-705 (firmware version: ___)
- Network: WiFi / Ethernet
- Host OS: macOS ___
- Radio IP: ___

### Results

| Test | Status | Notes |
|------|--------|-------|
| 1. Basic Connect/Query/Disconnect | PASS/FAIL | |
| 2. Rapid Query | PASS/FAIL | |
| 3. CW During Query | PASS/FAIL | |
| 4. Connection Recovery | PASS/FAIL | |
| 5. Concurrent Client | PASS/FAIL | |
| 6. Session Persistence | PASS/FAIL | |
| 7. CW Edge Cases | PASS/FAIL | |
| 8. Watch Mode | PASS/FAIL | |
| 9. Error Handling | PASS/FAIL | |
| 10. State Machine | PASS/FAIL | |

### Issues Found
- Issue 1: ...
- Issue 2: ...

### Sign-off
Tester: ___
Date: ___
```

---

## Next Steps After Testing

Once all tests pass:

1. **Commit test results** to `IC705SessionManager/TEST_RESULTS.md`
2. **Proceed to Phase 5**: React Native integration
3. **Create feature branch** for integration work
4. **Update main app** to use SessionManager instead of ad-hoc code
