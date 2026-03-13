# PoloRig IC-705 Integration Report

## Overview

This document captures the end-to-end integration work that brought the IC-705 native rig control module from "compiles but untested" to a working, tested feature within the PoloRig app. The work spanned native Swift code, React Native bridge plumbing, POLO's extension/hook system, iOS networking and permissions, automated test infrastructure, and UI enhancements.

---

## 1. Features Added

### 1.1 Connection Timeout (UDPBase.swift)

The original UDP connection code had no timeout. If the IC-705 was unreachable (powered off, wrong IP, wrong network), the app would hang indefinitely with the connect promise never settling.

**Solution:** Added a `DispatchSourceTimer`-based connect timeout (default 10 seconds) to `UDPBase`. The timer is armed when `connect()` is called and cancelled on successful handshake (`handleIAmReady`) or explicit disconnect. If it fires, `handleDisconnect()` tears down the connection and rejects the JS-side promise.

**Files:**
- `ios/polorig/RigControl/UDPBase.swift` — `connectTimer`, `armConnectTimer()`, timeout in `connect()`
- `IC705RigControl/Sources/IC705RigControl/UDPBase.swift` — same changes in CLI copy

### 1.2 CW-on-QRZ-Miss (callCommit Hook)

When a callsign is entered and QRZ lookup fails to find a name, the IC-705 automatically sends a CW query (e.g., `W1XYZ?`) over the air. This only fires once per callsign and only when the user commits the field (Enter, Tab, or Space — not on every keystroke).

**Architecture:**
- New `callCommit` hook category registered in POLO's extension registry (`src/extensions/registry.js`)
- `IC705Extension.js` registers a `CWCallCommitHook` with `onCallCommit` handler
- `MainExchangePanel.jsx` fires `callCommit` hooks from `onBlur` and `onSubmitEditing` on the callsign field
- A `cwSentCalls` Set prevents duplicate sends for the same callsign within a QSO

**Files:**
- `src/extensions/registry.js` — added `callCommit: []` to valid hook categories
- `src/extensions/other/ic705/IC705Extension.js` — `CWCallCommitHook` with `onCallCommit`
- `src/screens/.../MainExchangePanel.jsx` — `handleCallBlur` callback

### 1.3 Telegraph Key CW Send Button

A telegraph key button (using a photograph of a real Morse key) appears in the main exchange panel whenever the callsign field contains 3+ characters. Pressing it sends the CW template with the current callsign, regardless of whether QRZ lookup succeeded or failed. This allows ad-hoc CW queries at any time.

**Files:**
- `src/screens/.../MainExchangePanel.jsx` — `Pressable` + `Image` component with `sendCWQuery` handler
- `assets/telegraph-key.png` — telegraph key photograph used as button icon

### 1.4 App Lifecycle Cleanup (AppDelegate.swift)

The IC-705 only allows one RS-BA1 connection at a time. If the app was killed or backgrounded without sending a proper disconnect + token-remove sequence, the radio would remain locked to the stale session, preventing reconnection for up to 60 seconds.

**Solution:** Added `applicationWillTerminate` and `applicationDidEnterBackground` handlers that call `IC705RigControl.disconnectSync()` — a synchronous teardown that stops frequency polling, cancels CW, and sends disconnect packets on both control and serial ports.

**Files:**
- `ios/polorig/AppDelegate.swift` — terminate/background handlers
- `ios/polorig/IC705RigControl.swift` — `static weak var activeInstance`, `disconnectSync()`

### 1.5 CLI SIGINT Cleanup (rig-control-cli)

Same stale-session problem affected the Swift CLI tool. Killing it with Ctrl+C left the radio locked.

**Solution:** Added `signal(SIGINT)` handler that calls `doDisconnect()` before exiting.

**File:** `IC705RigControl/Sources/rig-control-cli/main.swift`

### 1.6 Promise Settlement Guard (IC705RigControl.swift)

The native module's `connect()` method could double-settle its JS promise — once from the `onSerialReady` callback (resolve) and again from `onDisconnect` (reject) if the connection dropped during handshake. This caused React Native bridge crashes.

**Solution:** Added a `var promiseSettled = false` guard that ensures exactly one of resolve/reject is called.

**File:** `ios/polorig/IC705RigControl.swift`

### 1.7 iOS Local Network Permissions (Info.plist)

Added required iOS permissions for local network access to the IC-705:
- `NSLocalNetworkUsageDescription` — user-facing explanation
- `NSBonjourServices` — `_rsba._udp` for RS-BA1 protocol discovery

**File:** `ios/polorig/Info.plist`

### 1.8 IC-705 Settings Section

The IC-705 extension registers a `setting` hook (category: `radio`) in POLO's settings system, adding an **IC-705 Rig Control** section to the Settings page. This provides configuration for WiFi connection parameters (IP address, RS-BA1 credentials, Home LAN vs Field AP mode), CW template, and auto-send-on-miss toggle.

**File:** `src/extensions/other/ic705/IC705Extension.js` — `registerHook('setting', { ... })`

---

## 2. Bugs Discovered and Fixed

### 2.1 DNS Resolution Failure on iOS Simulator

**Symptom:** Connection always failed with `NWConnection WAITING: -65554: NoSuchRecord` even though the CLI tool connected fine to the same IP.

**Root cause:** React Native's bridge passed the IP address string with trailing whitespace (e.g., `"192.168.2.144   "`). When `NWEndpoint.Host` received this padded string, it treated it as a hostname and attempted DNS resolution, which failed with `NoSuchRecord`.

**Fix:** Two changes in `UDPBase.init`:
1. Trim whitespace: `host.trimmingCharacters(in: .whitespacesAndNewlines)`
2. Explicitly parse as IPv4/IPv6 before falling back to hostname resolution:
```swift
if let ipv4 = IPv4Address(host) {
    self.host = .ipv4(ipv4)
} else if let ipv6 = IPv6Address(host) {
    self.host = .ipv6(ipv6)
} else {
    self.host = NWEndpoint.Host(host)
}
```

**Lesson:** iOS's `NWEndpoint.Host(string)` does not reliably detect IP addresses when whitespace is present. Always sanitize inputs from JS and prefer explicit `IPv4Address`/`IPv6Address` parsing.

### 2.2 CW Firing on Every Keystroke

**Symptom:** Typing a callsign caused rapid-fire QRZ lookups and CW transmissions on each character entered, flooding the radio.

**Root cause:** The original implementation used POLO's `lookup` hook, which fires via `useCallLookup` on every change to `qso?.their?.call` (every keystroke, by design — lookups should be eager).

**Fix:** Moved CW logic out of the `lookup` hook entirely. Created a new `callCommit` hook type that fires only when the user explicitly commits the callsign field (blur, Enter, Tab, or Space). This required:
1. Adding `callCommit` to the valid hook categories in `registry.js`
2. Creating the `CWCallCommitHook` in `IC705Extension.js`
3. Adding `onBlur` and wrapping `onSubmitEditing` in `MainExchangePanel.jsx`

**Lesson:** POLO's hook system validates categories at registration time. Custom hook categories must be added to the `Hooks` object in `registry.js` — the system logs `Invalid hook [name] for extension [key]` and silently drops the registration otherwise.

### 2.3 findHooks Destructuring Error

**Symptom:** `callCommit` hooks were registered but `onCallCommit` was never called.

**Root cause:** Code used `for (const { hook } of findHooks('callCommit'))` but `findHooks()` returns the `.hook` objects directly (via `.map(h => h.hook)`), not wrapped in `{ hook }`.

**Fix:** Changed to `for (const hook of findHooks('callCommit'))`.

### 2.4 Stale Radio Sessions

**Symptom:** After killing the CLI with Ctrl+C or force-quitting the app, the IC-705 rejected new connections for ~60 seconds.

**Root cause:** The RS-BA1 protocol requires a clean disconnect sequence (disconnect packet + token removal). Without it, the radio holds the session until its own timeout expires. The IC-705 only allows one RS-BA1 client at a time.

**Fix:** SIGINT handler in CLI, `applicationWillTerminate`/`applicationDidEnterBackground` in AppDelegate. Both call synchronous disconnect that sends the proper teardown packets.

---

## 3. Test Infrastructure

### 3.1 XCTest Target Added

Created `polorigTests` native test target in the Xcode project, enabling automated testing of the Swift rig control stack within the PoloRig build.

**Directory:** `ios/polorigTests/`

### 3.2 Tests Ported from IC705CWLogger (6 files)

| Test File | Coverage | Tests |
|---|---|---|
| `CIVConstantsTests.swift` | BCD frequency parsing, mode enums, CW speed encoding, CI-V frame building | 12 |
| `CIVControllerTests.swift` | CI-V response parsing, state tracking, error handling | 10 |
| `CWKeyerTests.swift` | Macro expansion, send buffer, Morse timing, serial numbers | 15 |
| `CWSidetoneTests.swift` | Morse code table validation, character coverage | 5 |
| `CWTemplateEngineTests.swift` | `$variable` interpolation, edge cases, unknown variables | 12 |

### 3.3 New Tests Written (3 files)

| Test File | Coverage | Tests |
|---|---|---|
| `PacketBuilderTests.swift` | Packet construction, byte layout, credential encoding | 8 |
| `PacketDefinitionsTests.swift` | Size constants, offset validation, timing ranges | 6 |
| `UDPBaseTests.swift` | Init state, sequence numbers, handshake flow, packet routing, disconnect cleanup | 18 |
| `UDPSerialTests.swift` | CI-V queue, ACK/NAK handling, unsolicited data, flush, disconnect | 11 |

**Total: ~97 automated tests** covering the rig control stack.

---

## 4. Files Modified Summary

### Native Swift (iOS)
| File | Changes |
|---|---|
| `ios/polorig/RigControl/UDPBase.swift` | Connect timeout, IPv4 parsing, whitespace trimming, diagnostic logging |
| `ios/polorig/IC705RigControl.swift` | Promise settlement guard, `activeInstance` singleton, `disconnectSync()` |
| `ios/polorig/AppDelegate.swift` | Terminate/background disconnect cleanup |
| `ios/polorig/Info.plist` | `NSLocalNetworkUsageDescription`, `NSBonjourServices` |
| `ios/polorig.xcodeproj/project.pbxproj` | Test target, file references, build settings |

### JavaScript (React Native)
| File | Changes |
|---|---|
| `src/extensions/registry.js` | Added `callCommit` hook category |
| `src/extensions/other/ic705/IC705Extension.js` | `callCommit` hook with `onCallCommit`, `cwSentCalls` tracking |
| `src/screens/.../MainExchangePanel.jsx` | `handleCallBlur`, telegraph key CW send button |

### CLI Tool
| File | Changes |
|---|---|
| `IC705RigControl/Sources/rig-control-cli/main.swift` | SIGINT handler for clean disconnect |

### Assets
| File | Description |
|---|---|
| `assets/telegraph-key.png` | Telegraph key photograph for CW send button |

### Tests (New)
| File | Description |
|---|---|
| `ios/polorigTests/` (9 files) | XCTest suite — 6 ported + 3 new test files |

---

## 5. Architecture Notes

### POLO Extension Hook System

POLO uses a registry-based hook system where extensions register hooks by category. Key details discovered during integration:

- **Valid categories are whitelist-enforced** — the `Hooks` object in `registry.js` defines all valid categories. Unrecognized categories are silently rejected with an error log.
- **`findHooks(category)`** returns hook objects directly (not wrapped), sorted by priority (descending).
- **`registerHook`** is called during extension activation via `onActivation({ registerHook })`.
- **Dynamic categories** matching `ref:\w+` are also allowed (used for reference handlers).

### RS-BA1 Protocol Constraints

- **Single-client limitation** — The IC-705 accepts exactly one RS-BA1 connection. A clean disconnect sequence (disconnect packet on both control and serial ports, token removal) is required to free the slot.
- **Two UDP ports** — Control port (default 50001) handles auth/tokens/capabilities. Serial port (default 50002) carries CI-V commands.
- **Token-based auth** — Login credentials are encoded with a proprietary codec (`CredentialCodec`), and the radio issues a session token used for all subsequent communication.
