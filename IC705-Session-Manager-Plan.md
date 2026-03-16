# IC-705 Session Management Refactoring via CLI Tool

## Context

The current IC-705 code uses an ad-hoc dual-session architecture (persistent + direct one-shot sessions) with complex timing-based synchronization. To achieve robustness before iPhone deployment, we will:

1. **Create a CLI tool** that exercises the same core session management code as the UI app
2. **Design clean session operations** that map to UI workflows
3. **Validate the design** by manually mimicking UI operations at the CLI
4. **Substitute into the main app** via a feature branch once proven

## UI Workflow Operations to Support

Based on analysis of the current code, the UI performs these radio interactions:

### 1. Connect (Settings -> Rig Control)
- Triggered by user tapping "Connect" in IC-705 settings
- Opens persistent control + serial session
- Authenticates with RS-BA1 credentials
- Maintains connection for UI state updates

### 2. Query Status (QSO Page Entry)
- Triggered when logging panel gains focus with a new/existing QSO
- Needs fresh frequency and mode from radio
- Must not interfere with any active CW sending
- Returns: frequency (Hz), mode (CW/USB/LSB/etc.)

### 3. Send CW (QSO Page - Callsign Commit or Manual)
- Triggered by callsign field blur or telegraph key button
- Sends CW text via CI-V command 0x17
- Must complete successfully or fail clearly
- May need to interrupt an in-progress status query

### 4. Disconnect/Cleanup (App Background/Terminate or Settings)
- Always available - radio only supports one client
- Must send proper RS-BA1 disconnect sequence
- Releases radio for other clients (CLI, RS-BA1 app, etc.)

## CLI Tool Design

### Command Structure

```bash
# 1. Connect - establishes persistent session
ic705-cli connect --host 192.168.2.144 --user USER --pass PASS
# Returns: session-id, radio-name, or error

# 2. Query status - fresh frequency/mode read
ic705-cli status [--session <id>]
# Returns: {"frequencyHz": 14060000, "mode": "CW", "connected": true}

# 3. Send CW
ic705-cli send-cw "W1AW?" [--session <id>]
# Returns: success/failure, time taken

# 4. Disconnect
ic705-cli disconnect [--session <id>]
# Always succeeds (idempotent)

# 5. Watch/Monitor mode (optional but useful)
ic705-cli watch [--session <id>]
# Streams frequency/mode changes until Ctrl+C
```

### Shared Core Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      CLI Tool (Swift)                       │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │ ConnectCmd   │  │ StatusCmd    │  │ SendCWCmd       │   │
│  └──────────────┘  └──────────────┘  └─────────────────┘   │
└────────────────────┬───────────────────────────────────────┘
                     │
┌────────────────────▼───────────────────────────────────────┐
│              Session Manager (Shared Library)              │
│                                                            │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  Session State Machine                              │  │
│  │                                                     │  │
│  │   ┌─────────┐    connect     ┌─────────────┐       │  │
│  │   │  IDLE   │ ─────────────► │ CONNECTING  │       │  │
│  │   └─────────┘                └─────────────┘       │  │
│  │       ▲                            │               │  │
│  │       │ disconnect                 │ ready         │  │
│  │       │                            ▼               │  │
│  │   ┌─────────┐                ┌─────────────┐       │  │
│  │   │DISCON-  │ ◄──────────────│  CONNECTED  │       │  │
│  │   │NECTING  │   disconnect   │  (persistent)│      │  │
│  │   └─────────┘                └─────────────┘       │  │
│  │                                    │               │  │
│  │                    query/status    │ query/status  │  │
│  │                            ┌───────┴───────┐       │  │
│  │                            ▼               ▼       │  │
│  │                    ┌─────────────┐  ┌─────────────┐│  │
│  │                    │   QUERYING  │  │ SENDING_CW  ││  │
│  │                    │  (one-shot) │  │  (one-shot) ││  │
│  │                    └─────────────┘  └─────────────┘│  │
│  │                            │               │       │  │
│  │                            └───────┬───────┘       │  │
│  │                                    │ complete      │  │
│  │                                    ▼               │  │
│  │                            ┌─────────────┐        │  │
│  │                            │ RECONNECTING│        │  │
│  │                            │(restore pers│        │  │
│  │                            └─────────────┘        │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                            │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  UDP Transport Layer (UDPControl + UDPSerial)       │  │
│  │  - Existing PacketBuilder, CIV encoding             │  │
│  │  - Timeout and retry logic                          │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                            │
└────────────────────────────────────────────────────────────┘
                     │
                     │ (shared library/.framework)
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                 React Native App (iOS)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │ useIC705 hook│  │ LoggingPanel │  │ Settings Screen │   │
│  │              │  │ status fx    │  │ connect/discon  │   │
│  └──────────────┘  └──────────────┘  └─────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### 1. Session State Machine (Replaces Ad-Hoc Synchronization)

**Current Problem**: `directOperationBusyUntil` timestamp, multiple flags, complex ref-based deduplication

**New Approach**: Explicit state machine with serialized operations

```swift
enum SessionState {
    case idle                    // Persistent session active, ready
    case connecting              // In handshake
    case connected               // Persistent session ready
    case queryingStatus          // One-shot status read in progress
    case sendingCW               // One-shot CW send in progress
    case reconnecting            // Restoring persistent session after one-shot
    case disconnecting           // Clean shutdown in progress
    case disconnected            // No session
}

// Operations are queued and executed serially
func enqueue(_ operation: RadioOperation) async throws -> OperationResult
```

### 2. Operation Queue (Prevents Race Conditions)

Instead of multiple code paths potentially conflicting:
- All operations go through a serial queue
- State transitions are atomic
- Only one operation active at a time
- UI can still cancel queued operations

### 3. Shared Library Structure

```
sources/
├── SessionManager/           # Core session management
│   ├── SessionManager.swift  # Main API, state machine, queue
│   ├── SessionState.swift    # State enum and transitions
│   └── RadioOperation.swift  # Operation types
├── Transport/                # UDP + CI-V (existing code, extracted)
│   ├── UDPControl.swift
│   ├── UDPSerial.swift
│   ├── PacketBuilder.swift
│   └── CIV/
│       ├── CIVController.swift
│       └── CIVConstants.swift
└── CLI/                      # CLI-specific
    ├── Commands/
    │   ├── ConnectCommand.swift
    │   ├── StatusCommand.swift
    │   ├── SendCWCommand.swift
    │   └── DisconnectCommand.swift
    └── main.swift
```

### 4. Error Handling Strategy

All operations return a `Result<T, RadioError>`:

```swift
enum RadioError: Error {
    case notConnected
    case alreadyConnecting
    case timeout(operation: String, duration: TimeInterval)
    case authenticationFailed
    case radioBusy  // Another client has the radio
    case networkError(Error)
    case invalidResponse
    case operationCancelled
}
```

## CLI Tool Implementation Plan

### Phase 1: Extract and Refactor Transport Layer (Week 1)

**Goal**: Make UDPControl/UDPSerial usable as a library

**Tasks**:
1. Create new Swift package structure
2. Extract existing transport code (no behavior changes yet)
3. Remove React Native dependencies from transport layer
4. Add unit tests for extracted code (port existing tests)

**Files to Create**:
- `IC705SessionManager/Package.swift`
- `IC705SessionManager/Sources/Transport/UDPControl.swift` (extracted)
- `IC705SessionManager/Sources/Transport/UDPSerial.swift` (extracted)
- `IC705SessionManager/Tests/TransportTests/` (ported tests)

### Phase 2: Implement Session Manager (Week 2)

**Goal**: State machine and operation queue

**Tasks**:
1. Define `SessionState` enum with valid transitions
2. Implement `SessionManager` class with operation queue
3. Implement `RadioOperation` protocol and concrete types:
   - `ConnectOperation`
   - `QueryStatusOperation`
   - `SendCWOperation`
   - `DisconnectOperation`
4. Add comprehensive unit tests for state machine

**Key Design Points**:
- Use `actor` or serial `DispatchQueue` for thread safety
- Operations are async/await based
- State changes emit notifications (for UI integration later)

**Files to Create**:
- `IC705SessionManager/Sources/SessionManager/SessionManager.swift`
- `IC705SessionManager/Sources/SessionManager/SessionState.swift`
- `IC705SessionManager/Sources/SessionManager/Operations/*.swift`
- `IC705SessionManager/Tests/SessionManagerTests/*.swift`

### Phase 3: Build CLI Tool (Week 2-3)

**Goal**: Command-line interface exercising all operations

**Tasks**:
1. Create CLI executable target
2. Implement commands using swift-argument-parser
3. Add session persistence file (so session-id can be reused across commands)
4. Add verbose logging mode (for debugging)

**CLI Commands**:
```bash
# Connect and save session
ic705-cli connect --host 192.168.2.144 --user ADMIN --pass PASS --save
# Saves session to ~/.config/ic705/session.json

# Query (uses saved session)
ic705-cli status

# Send CW
ic705-cli send-cw "CQ CQ DE W1AW K"

# Disconnect and clear saved session
ic705-cli disconnect --clear
```

**Files to Create**:
- `IC705SessionManager/Sources/CLI/main.swift`
- `IC705SessionManager/Sources/CLI/Commands/*.swift`

### Phase 4: Manual Testing Protocol (Week 3)

**Goal**: Validate CLI mimics UI operations correctly

**Test Scenarios**:

1. **Basic Connect -> Query -> Disconnect**
   ```bash
   ic705-cli connect --host <ip> --user <user> --pass <pass>
   ic705-cli status
   ic705-cli disconnect
   ```

2. **Rapid Query Test** (simulates QSO page focus changes)
   ```bash
   ic705-cli connect --host <ip> --user <user> --pass <pass>
   for i in {1..10}; do ic705-cli status; sleep 1; done
   ic705-cli disconnect
   ```
   Expected: All queries succeed, no radio lock

3. **CW During Query** (simulates user sending CW while status refreshing)
   ```bash
   ic705-cli connect --host <ip> --user <user> --pass <pass>
   ic705-cli status &  # Background
   ic705-cli send-cw "TEST"
   wait
   ic705-cli disconnect
   ```
   Expected: Operations serialize properly, no crash

4. **Connection Recovery** (simulates network hiccup)
   ```bash
   ic705-cli connect --host <ip> --user <user> --pass <pass>
   # Unplug radio network briefly
   ic705-cli status
   ic705-cli disconnect
   ```
   Expected: Clear error, clean disconnect

5. **Concurrent Client Test** (verifies radio single-client enforcement)
   ```bash
   # Terminal 1
   ic705-cli connect --host <ip> --user <user> --pass <pass>

   # Terminal 2 (should fail or steal connection)
   ic705-cli connect --host <ip> --user <user> --pass <pass>
   ```
   Expected: Clear error or proper session handoff

### Phase 5: React Native Integration (Week 4)

**Goal**: Replace ad-hoc code with SessionManager

**Tasks**:
1. Create feature branch
2. Add SessionManager as local Swift package dependency
3. Rewrite `IC705RigControl.swift` to use SessionManager
4. Keep same JS-facing API (no JS changes needed)
5. Test all UI workflows

**Files to Modify**:
- `ios/polorig/IC705RigControl.swift` - Replace with SessionManager wrapper
- `ios/polorig.xcodeproj/project.pbxproj` - Add package dependency
- Remove: `DirectCWSender.swift`, `DirectStatusReader` logic (moved to SessionManager)

## Migration Strategy

### Immediate Feature Branch

Create a feature branch immediately to isolate all changes from main:

```bash
git checkout -b feature/ic705-session-manager
git push -u origin feature/ic705-session-manager
```

All work (CLI tool, SessionManager, integration) happens on this branch. Commits and pushes happen at each milestone.

### Backward Compatibility

The JS-facing API remains unchanged:
```swift
// Existing methods kept, implementation delegates to SessionManager
@objc func connect(_ host: String, username: String, password: String, ...)
@objc func disconnect(...)
@objc func sendCW(_ text: String, ...)
@objc func refreshStatus(...)
```

### Development Workflow

1. **Feature Branch**: `feature/ic705-session-manager` - all development here
2. **Milestone Commits**: Commit and push at each completed phase
3. **Simulator Testing**: Verify all existing functionality
4. **Physical Radio Testing**: Test with actual IC-705
5. **TestFlight Beta**: Limited user testing (still on feature branch)
6. **Production**: PR and merge to main when ready

## Success Criteria

### CLI Tool
- [ ] All 5 test scenarios pass reliably
- [ ] No crashes under rapid operation
- [ ] Clear error messages for all failure modes
- [ ] Operations serialize correctly (no race conditions)

### Integration
- [ ] All existing UI functionality preserved
- [ ] No regression in test suite
- [ ] Improved stability in TestFlight (fewer radio disconnects)

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| SessionManager has bugs not caught in CLI testing | Extensive unit tests + simulator testing |
| React Native bridge incompatibility | Keep same JS API, only change Swift implementation |
| Performance regression | Benchmark CLI vs old code, profile if needed |
| Build complexity (local package) | Document setup, consider git submodule or local path |

## Next Steps

1. **Create feature branch** `feature/ic705-session-manager` and push to origin
2. **Create repository structure** - Set up the Swift package
3. **Implement Phase 1** - Extract transport layer
4. **Commit and push** milestone
5. **Implement Phase 2** - Build SessionManager with state machine
6. **Commit and push** milestone
7. **Build CLI** - Exercise the new code
8. **Commit and push** milestone
9. **Test iteratively** - Validate each scenario
10. **Integrate** - Substitute into main app
11. **Commit and push** milestone
