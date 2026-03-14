# IC-705 Work Summary

Date: 2026-03-14

## Outcome

The IC-705 integration is now in a materially better state:

- CW send from the QSO page works again.
- The app builds reliably with the custom Swift IC-705 code included.
- Development defaults for operator and IC-705 settings are loading again.
- QRZ lookup no longer fires while typing in the callsign field.
- The logging/QSO page now tracks radio frequency and mode in the actual QSO controls.

The remaining work is no longer basic transport bring-up. The remaining work is mostly cleanup, stabilization, and reducing refresh noise.

## UI Work

### Logging and QSO page behavior

- Added QSO-page radio sync logic so the Frequency and Mode fields can reflect the connected IC-705.
- Refined the trigger model so radio state is refreshed on page entry and on the logging panel reopen path.
- Removed the extra IC-705 status strip from the logging panel after frequency tracking was working in the real fields.
- Preserved normal QSO field updates while removing the debug/status-only UI.

### Callsign lookup behavior

- Changed callsign lookup flow so QRZ/callsign lookup is disabled while the user is typing.
- Re-enabled lookup only after blur/submit/commit of the callsign field.
- Result: lookup now happens after leaving the field, not after “enough characters”.

### Development defaults

- Added a development-defaults path so clean deploys can populate:
  - operator callsign
  - default grid
  - QRZ credentials
  - IC-705 connection credentials
- Fixed the merge behavior so blank persisted values do not override `.env.local`.

### Debug UI cleanup

- Removed temporary popups used to prove the JS-to-native CW path.
- Removed the extra status strip once the real QSO fields were updating.

## Native Code Work

### Build and bridge repair

- Repaired the React Native iOS bootstrap/codegen path so the app builds again.
- Fixed the native bridge export situation so `sendCW` and related methods are actually available at runtime.
- Added explicit build signaling and auto-install tooling for simulator builds.

### CW transport

- Confirmed the app was originally failing before the radio because the runtime bridge did not expose the full native module.
- Once the bridge was fixed, confirmed the app could reach native CW.
- Identified that the most reliable reference behavior was the standalone Swift script, not the persistent `UDPSerial` session.
- Reworked the CW send path to use a direct script-style session:
  - drop the persistent app session
  - open a fresh control + serial session
  - send the CW command
  - close the temporary session
  - restore the persistent session
- Fixed credential fallback so the direct sender can use authenticated control-session credentials when persisted settings are blank.

### Radio status retrieval

- Confirmed persistent-session status was not reliable enough for mode and sometimes stale for frequency.
- Added a direct script-style status reader for one-shot radio refreshes.
- That direct reader now successfully retrieves:
  - frequency via CI-V `0x03`
  - mode via CI-V `0x04`

### Logging and diagnostics

- Added native trace/file logging for:
  - CW entry and result
  - UI trace markers
  - UDP serial/control packets
  - direct CW sender
  - direct status reader
- Added simulator log capture and build-status scripts so debugging no longer depends on manual Console filtering.

## Important Findings

### What turned out to be true

- The working standalone Swift script is the best reference for the limited IC-705 semantics this app currently needs.
- The app’s original persistent `UDPSerial` strategy was too fragile for reliable CW and status retrieval.
- The bridge/export layer caused a large part of the apparent CW failure early on.
- The radio query itself is now working for both frequency and mode.

### What was misleading at first

- “CW FAIL” was initially interpreted as a radio transport failure, but an early blocker was that `sendCW` was not exported in the runtime native module.
- Missing defaults looked like persistence failure, but the real issue was merge precedence between persisted settings and dev defaults.
- Wrong mode display looked at first like radio query failure, but part of it was app-side mode override behavior and stale status handling.

## Current State

- QSO-page CW send: working
- QSO-page mode display: working
- QSO-page frequency display: working in the latest reported state
- Extra debug/status strip: removed
- Build and simulator deployment: working with the signaling script

## Suggested Next Steps

- Reduce redundant refreshes; the direct status refresh is firing more often than necessary.
- Collapse the current refresh logic to one clear trigger path for the logging panel.
- Add tests around:
  - direct status reader
  - VFO reducer behavior when explicit mode is present
  - logging panel radio-refresh triggers
