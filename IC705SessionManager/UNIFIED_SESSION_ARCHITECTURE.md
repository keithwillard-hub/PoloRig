# Unified Long-Lived Session Manager

## Purpose

`IC705SessionManager` now contains a persistent RS-BA1 session model intended to replace the ad hoc one-shot transport flow previously used by PoloRig.

The design goal is simple:

- keep one authenticated control session open
- keep one CI-V serial session open
- serialize radio operations through that session
- disconnect cleanly so the IC-705 releases its single client slot

This package remains independently testable through the CLI tools before any app integration.

## Why This Exists

The older native PoloRig implementation mixed two patterns:

- a persistent connection for app-level connection state
- direct one-shot sessions for status reads and CW send

That approach worked, but it had structural problems:

- operation flow was split across multiple implementations
- disconnect/reconnect churn increased timing sensitivity
- the radio only allows one RS-BA1 client at a time
- reconnect timing after a one-shot operation was fragile

The new unified model keeps the proven wire behavior while moving it behind one persistent session service.

## High-Level Architecture

There are three layers:

1. Transport
2. Persistent session service
3. CLI and app-facing adapters

### 1. Transport

Transport lives in [`Sources/Transport`](./Sources/Transport).

- [`UDPBase.swift`](./Sources/Transport/UDPBase.swift)
  - generic UDP socket lifecycle
  - RS-BA1 handshake
  - ping/idle handling
  - disconnect packet handling
- [`UDPControl.swift`](./Sources/Transport/UDPControl.swift)
  - RS-BA1 login
  - token management
  - capabilities exchange
  - connection info and status exchange
  - negotiated CI-V port discovery
- [`UDPSerial.swift`](./Sources/Transport/UDPSerial.swift)
  - CI-V stream open/close
  - queued CI-V command execution
  - reply tracking and ACK/NAK handling

This layer is intentionally close to wfview’s model:

- separate control and serial sockets
- negotiated stream setup
- keepalive traffic on both channels
- explicit token removal and stream close during disconnect

### 2. Persistent Session Service

The core service is [`PersistentRadioSession.swift`](./Sources/SessionManager/PersistentRadioSession.swift).

It is the long-lived session abstraction used by both the CLI acceptance harness and the future app-side integration.

Responsibilities:

- establish one persistent control session
- open one persistent CI-V serial session
- expose serialized async operations
- track and bound operation timeouts
- translate raw CI-V responses into typed results
- perform orderly disconnect with:
  - serial close
  - token remove
  - control disconnect

Public operations:

- `connect()`
- `queryStatus()`
- `queryCWSpeed()`
- `setCWSpeed(_:)`
- `sendCW(_:)`
- `disconnect()`

Internally, the service enforces one active operation at a time through an internal `PendingOperation` state and a dedicated dispatch queue.

## Operation Model

Each operation is serialized over the same live session.

### Connect

`connect()` performs:

1. control socket open
2. RS-BA1 discovery and authentication
3. control status exchange
4. serial socket open on the negotiated CI-V port
5. CI-V `OpenClose(open)` handshake

When the serial side is ready, the session is considered connected.

### Query Status

`queryStatus()` runs over the live CI-V session and requests:

- frequency
- mode

It does not tear down and recreate the session.

### Query CW Speed

`queryCWSpeed()` first warms up the stream by reading frequency and mode, then requests CW speed.

This mirrors the sequence that proved reliable against the radio in live testing.

### Set CW Speed

`setCWSpeed(_:)` sends a CI-V `0x14 / 0x0C` level write over the live session and completes on ACK.

### Send CW

`sendCW(_:)` sends CI-V `0x17` over the live serial stream as a fire-and-forget operation, then waits a short bounded period before reporting success.

That delay preserves the radio behavior validated during CLI testing and avoids disconnecting immediately after the send is queued.

### Disconnect

`disconnect()` sends:

1. serial `OpenClose(close)`
2. control token remove
3. control disconnect

Then it waits briefly before releasing local transport references. This is not a fully acknowledged shutdown protocol, but it is a much stronger teardown than the earlier fire-and-exit behavior.

## Acceptance Harnesses

Two CLI entrypoints remain important.

- [`ic705-cli`](./Sources/CLI/IC705CLI.swift)
  - command-oriented testing
- [`ic705-session-cli`](./Sources/SequenceCLI/main.swift)
  - full persistent-session acceptance test

The key acceptance harness is `ic705-session-cli`, which runs one long-lived session through:

1. connect
2. query CW speed
3. query frequency and mode
4. send CW
5. disconnect

That command is the closest pre-integration proof that the app-facing model is viable.

## Relationship To PoloRig Integration

The intended migration path is:

1. keep the package independently testable
2. integrate the iOS app against `PersistentRadioSession`
3. preserve the existing React Native JS surface
4. validate the app manually using the branch launch scripts

Relevant branch launch scripts in the repo root:

- [`start_polorig.sh`](../start_polorig.sh)
- [`start_polorig_dev.sh`](../start_polorig_dev.sh)
- [`stop_polorig.sh`](../stop_polorig.sh)
- [`stop_polorig_dev.sh`](../stop_polorig_dev.sh)

The package CLI should remain usable right up to the point where the PoloRig native transport swap is complete. It is the fastest way to determine whether a regression is in the shared session layer or in the app integration.

## Current Constraints

- The IC-705 remains single-client.
- Operation overlap must be avoided.
- Disconnect timing still matters.
- App integration should preserve explicit lifecycle management on background and termination.

## Files To Start With

If you need to understand the implementation quickly, start here:

- [`PersistentRadioSession.swift`](./Sources/SessionManager/PersistentRadioSession.swift)
- [`PersistentSequenceRunner.swift`](./Sources/SessionManager/PersistentSequenceRunner.swift)
- [`SessionManager.swift`](./Sources/SessionManager/SessionManager.swift)
- [`UDPControl.swift`](./Sources/Transport/UDPControl.swift)
- [`UDPSerial.swift`](./Sources/Transport/UDPSerial.swift)
- [`main.swift`](./Sources/SequenceCLI/main.swift)
