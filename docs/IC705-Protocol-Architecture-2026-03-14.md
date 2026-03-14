# IC-705 Protocol And Architecture

Date: 2026-03-14

## Scope

This document describes the limited IC-705 semantics currently implemented in `PoloRig`:

- connect/authenticate
- open serial CI-V channel
- read frequency
- read mode
- send CW text
- disconnect/cleanup

It also explains the architectural difference between the original mental model and the current, working model.

## The Protocol In Practice

The app is not speaking raw CI-V directly to the radio over a single socket.

It is speaking the Icom RS-BA1-style UDP protocol in two layers:

1. Outer UDP session/control protocol
2. Inner CI-V frames carried inside RS-BA1 serial packets

### Ports used

- UDP `50001`: control/authentication/session management
- UDP `50002`: serial/CI-V channel
- UDP `50003`: audio channel placeholder in `connInfo`, though audio is not the focus here

### Control/session layer

The control layer performs:

- discovery / `areYouThere`
- readiness handshake / `areYouReady`
- login request with encoded credentials
- token exchange and token acknowledge
- capability/status exchange
- session metadata exchange (`connInfo`)
- disconnect / token remove

Important code:

- [UDPBase.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/UDPBase.swift)
- [UDPControl.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/UDPControl.swift)
- [PacketBuilder.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/PacketBuilder.swift)

### Serial/CI-V layer

Once the control path yields status and the remote CI-V port, the app opens the serial path and sends:

- serial discovery / `areYouThere`
- serial ready handshake / `areYouReady`
- serial `OpenClose(isOpen: true)`
- CI-V frames wrapped inside a `0xC1` RS-BA1 serial packet

The CI-V frames currently used are:

- `0x03`: read frequency
- `0x04`: read mode
- `0x14 0C`: CW speed level
- `0x17`: send CW

Important code:

- [UDPSerial.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/UDPSerial.swift)
- [CIVController.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/CIVController.swift)
- [CIVConstants.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/CIVConstants.swift)

## Limited Semantics The App Implements

### Connect

Persistent app connection:

1. Open UDP control socket to `50001`
2. Complete RS-BA1 control handshake
3. Authenticate with encoded username/password
4. Receive token and status metadata
5. Open UDP serial socket to the advertised remote CI-V port
6. Complete serial handshake
7. Send `OpenClose(isOpen: true)`
8. Mark app “connected”

### Read Frequency

Two paths exist now:

- persistent-session path:
  - uses existing `CIVController` / `UDPSerial`
  - frequency can become stale depending on session behavior
- direct-status path:
  - create fresh temporary control + serial session
  - send CI-V `0x03`
  - parse BCD frequency response
  - close temporary session

### Read Mode

Mode is now read reliably through the direct-status path:

1. create fresh temporary control + serial session
2. send CI-V `0x04`
3. parse returned mode byte
4. map mode byte to label (`CW`, `USB`, `LSB`, etc.)
5. close temporary session

### Send CW

CW uses a direct session, not the persistent status session:

1. accept the CW request even if the persistent `isConnected` flag is stale
2. temporarily disconnect the persistent session
3. block direct status refresh while the CW direct session is active
4. wait briefly for the radio to release the prior session
5. open fresh control + serial session
6. send serial `OpenClose(isOpen: true)`
7. send CI-V `0x17` with ASCII text payload
8. wait briefly for the radio to act on it
9. close temporary session
10. reconnect the persistent app session

This path is based on the standalone Swift script because that path proved reliable against the radio, but the working app implementation is not a byte-for-byte clone of the script. The important property is the direct one-shot session lifecycle, not literal source parity.

## Architectural Diagram

```text
React UI
  |
  v
useIC705()
  |
  v
IC705RigControl.js
  |
  v
React Native bridge
  |
  v
IC705RigControl.swift
  |-------------------------------|
  |                               |
  | persistent session            | direct one-shot sessions
  |                               |
  v                               v
UDPControl + UDPSerial        DirectCWSender / DirectStatusReader
  |                               |
  | control: UDP 50001            | control: UDP 50001
  | serial:  UDP 50002            | serial:  UDP 50002
  v                               v
RS-BA1 UDP packet layer       RS-BA1 UDP packet layer
  |
  v
CI-V frames
  |
  v
IC-705
```

## Current Solution

### Persistent session responsibilities

The persistent app session is now mainly responsible for:

- user-visible connection state
- long-lived app connectivity
- some live event propagation
- being restored after direct operations complete

### Direct-session responsibilities

Direct one-shot sessions are now responsible for the operations that must be correct:

- CW send
- fresh frequency read
- fresh mode read

This is the key architectural shift.

## Original Understanding Versus Actual Behavior

### Original understanding

The original working assumption was:

- one persistent serial session would be enough
- CI-V polling and CW could coexist on that session
- `getStatus()` from the persistent controller was the main source of truth
- the app could behave like a conventional continuously attached rig-control client

### What the radio/app actually showed

What the debugging proved instead:

- the persistent serial session was fragile
- it could be “connected” enough to exchange low-level packets but still fail to deliver usable CI-V responses
- CW and status requests were more reliable when executed in a fresh, script-style session
- the app’s bridge/export layer and state propagation problems obscured the true transport behavior

### The practical correction

The corrected architecture is:

- keep the persistent session for app presence
- use direct script-style sessions for correctness-sensitive operations
- do not let status refresh contend with a CW direct session
- treat a stale persistent `isConnected` flag as advisory for CW, not authoritative
- treat the direct-session path as the trusted source when the persistent path is incomplete or stale

## Why The Direct Session Works Better

The standalone script demonstrated three important facts:

- the radio accepts a one-shot `0x17` CW command in a fresh session
- the radio responds correctly to one-shot `0x03` and `0x04` requests
- the radio cleans up cleanly when the temporary client explicitly closes and disconnects

That means the app’s most reliable strategy for the implemented subset is not “keep everything on the persistent session.” It is “use a known-good one-shot flow for each correctness-sensitive operation, and keep other direct operations out of its way while it runs.”

## Working Baseline

The currently verified working CW baseline is commit `d7b9cec` on `main`.

## Code Areas That Define The Current Architecture

### Native

- [IC705RigControl.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/IC705RigControl.swift)
- [IC705RigControlBridge.m](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/IC705RigControlBridge.m)
- [DirectCWSender.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/DirectCWSender.swift)
- [UDPControl.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/UDPControl.swift)
- [UDPSerial.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/UDPSerial.swift)
- [CIVController.swift](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/RigControl/CIVController.swift)

### JS / UI

- [IC705RigControl.js](/Users/keithwillard/projects/iphone_dev/PoloRig/src/native/IC705RigControl.js)
- [useIC705.js](/Users/keithwillard/projects/iphone_dev/PoloRig/src/hooks/useIC705.js)
- [OpLoggingTab.jsx](/Users/keithwillard/projects/iphone_dev/PoloRig/src/screens/OperationScreens/OpLoggingTab/OpLoggingTab.jsx)
- [LoggingPanel.jsx](/Users/keithwillard/projects/iphone_dev/PoloRig/src/screens/OperationScreens/OpLoggingTab/components/LoggingPanel.jsx)
- [stationSlice.js](/Users/keithwillard/projects/iphone_dev/PoloRig/src/store/station/stationSlice.js)

## Remaining Architectural Risks

- The refresh trigger logic in the logging panel is still more complicated than it should be.
- The direct refresh path is correct, but it has recently been firing more often than desired.
- Persistent-session status and direct-session status still coexist, which increases state-merging complexity.

## Recommended Simplification

If this code is revisited, the best simplification would be:

1. Keep persistent connect/disconnect state.
2. Make radio status refresh an explicit, single trigger owned by the logging panel lifecycle.
3. Make that refresh always use the direct status reader.
4. Push the returned freq/mode into one clear source of truth.
5. Remove duplicate refresh effects once behavior is stable.
