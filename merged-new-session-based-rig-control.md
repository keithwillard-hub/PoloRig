# Merged New Session-Based Rig Control

## Overview
- Unified CLI and app now share `IC705SessionManager` with a persistent session abstraction (`PersistentRadioSession`). The CLI (`ic705-session-cli`) sequentially runs: connect, speed query, status query, CW transmit, disconnect. The app-side rig control now drives the same session via `SessionManager`, ensuring single-session serialization and explicit tear-down.
- Transport code (`UDPControl`, `UDPSerial`, packet builders) mirrors the wfview handshake by binding sockets, advertising local ports, tracking packet sequencing, and keeping alive ping/idle traffic.

## App integration
- `IC705RigControl.swift` owns `SessionManager` lifecycle, logs stage status, and routes connect/status/speed/CW commands through the persistent session. Polling guards use a generation counter and explicit disconnect clears cached credentials.
- Launch scripts (`start_polorig.sh`, dev/prod variants) wait for Metro bundle readiness before touching the simulator, ensuring stable start/stop flows.

## Testing and verification
- `swift test` within `IC705SessionManager` passes.
- Clean iOS workspace build (`xcodebuild -workspace ios/polorig.xcworkspace -scheme polorig -configuration DevDebug -sdk iphonesimulator`) succeeds.
- App launch via `start_polorig_dev.sh` with Metro externally running works and supports manual radio testing (access-mode credentials: host `192.168.59.1`, user `kew`, pass `qwerty12345`).
- CLI `ic705-session-cli` and opera commands validated for connect/status/speed/send-cw against actual radio, plus manual app run proving frequency tracking and CW send.

## Remaining work
- Monitor the JS “result function returned its own inputs” warning; prior selector cleanup targeted known pass-throughs but issue persists on first-load. If it keeps firing, capture exact selector name from Metro console for targeted fix.
- Continue logging hardening, disconnect validation, and integration tests before closing out this feature branch.
