# PoloRig: Porting Swift to Browser JavaScript — Analysis

## Question

Can the Swift rig control code (keyer, network layer, protocols) be ported to JavaScript running in a browser?

## Summary

The **logic** ports fine, but **browsers cannot open raw UDP sockets**, which is a hard blocker for talking directly to the IC-705 over WiFi.

---

## What Ports Easily to Browser JS

| Swift Layer | Browser JS Equivalent | Difficulty |
|---|---|---|
| CW Template Engine (`$variable` interpolation) | Native string manipulation | Trivial |
| CW Keyer (timing, chunking, pacing) | `setTimeout` / `setInterval` | Easy |
| CI-V protocol parsing/building | `ArrayBuffer`, `DataView`, `Uint8Array` replace Swift `Data` | Moderate |
| RS-BA1 packet construction | Same binary tools as CI-V | Moderate |
| CW Sidetone (audio feedback) | Web Audio API (oscillator nodes, gain envelopes) | Easy |

All of the protocol logic, keyer state machine, and audio generation have direct browser equivalents.

---

## The Blocker: UDP Transport

Browsers have **no raw UDP socket API**. There is no equivalent to Swift's `Network.framework` or Node.js's `dgram` module. The IC-705's RS-BA1 protocol requires UDP communication on ports 50001 (control) and 50002 (serial/CI-V). This cannot be done from pure browser JavaScript.

Relevant browser APIs that do NOT solve this:
- **WebSocket** — TCP-based, requires a WebSocket server (IC-705 doesn't have one)
- **WebRTC** — Uses UDP internally but for media streams, not arbitrary packets
- **WebTransport** — Uses QUIC/UDP but requires a WebTransport server on the other end
- **Chrome Apps raw sockets** — Deprecated and removed

---

## Practical Workarounds

### Option 1: WebSocket-to-UDP Proxy (Most Practical)

A small server sits on the local network and relays packets between the browser and IC-705:

```
Browser (JS)  ←— WebSocket —→  Proxy Server  ←— UDP —→  IC-705
                                (Node.js/Python)         (ports 50001/50002)
```

- The proxy is a "dumb pipe" — just forwarding bytes in both directions
- All protocol logic (RS-BA1, CI-V, keyer) stays in the browser JS
- Could run on the same machine, a Raspberry Pi, or any device on the network
- Approximately 50 lines of Node.js code
- Keeps the WiFi connection to the radio

### Option 2: Electron or Tauri Desktop App

- Wraps browser-like UI (HTML/JS/CSS) with native capabilities
- Electron gives access to Node.js `dgram` module (UDP sockets)
- Tauri gives access via Rust backend
- Not truly "in browser" but the UI layer is web technology
- No proxy needed — direct UDP access from the app

### Option 3: WebSerial API (USB instead of WiFi)

- Browsers CAN talk to serial ports via the WebSerial API
- IC-705 supports CI-V over USB serial (no RS-BA1/UDP needed)
- Direct browser-to-radio communication, no proxy
- **Trade-off:** Requires wired USB connection, loses WiFi mobility
- CI-V over USB serial is simpler than RS-BA1 (no authentication handshake)

---

## Recommendation

If the goal is a **true browser app with WiFi**, Option 1 (WebSocket-to-UDP proxy) is the most practical path. The proxy is minimal, and the bulk of the code — protocol handling, keyer logic, template engine, sidetone — lives in portable JavaScript.

If **USB is acceptable**, Option 3 (WebSerial) eliminates the proxy entirely and is the simplest architecture, but sacrifices wireless operation.
