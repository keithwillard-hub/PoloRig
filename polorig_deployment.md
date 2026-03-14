# PoloRig Deployment

## Deploying To iPhone

To install `PoloRig` on an iPhone, use Xcode.

Steps:
1. Connect the iPhone to the Mac with USB.
2. On the iPhone, tap `Trust This Computer` if prompted.
3. Open [ios/polorig.xcworkspace](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig.xcworkspace) in Xcode.
4. In Xcode, select the `polorig` scheme.
5. Select the physical iPhone as the run destination.
6. In the `polorig` target, check `Signing & Capabilities`.
7. Confirm your Apple team is selected.
8. Press `Run`.

Notes:
- Xcode will do a new build for the physical device automatically.
- A simulator build cannot be installed on an iPhone.
- The project is already configured for automatic signing.
- Current team in the project is `T56H72Q4W5`.
- Current production bundle identifier is `com.ac0vw.polorig.prod`.

## If Xcode Prompts For Fixes

Possible issues and fixes:

- `Bundle identifier unavailable`
  - Change the app target bundle identifier to a unique value under `Signing & Capabilities`.

- `Developer Mode required`
  - On iPhone: `Settings > Privacy & Security > Developer Mode`

- `Untrusted developer`
  - On iPhone: `Settings > General > VPN & Device Management`
  - Trust the Apple ID / team used to sign the app.

- Local defaults missing
  - Make sure [`.env.local`](/Users/keithwillard/projects/iphone_dev/PoloRig/.env.local) exists on this Mac before building from Xcode.

## Risk After Rebuild

There is some chance the app behaves differently on iPhone than in the simulator, but the likely causes are device-specific rather than the same rebuild problem seen earlier.

What is stable:
- The current committed app code is working again in the simulator.
- The IC-705 transport code is back on the known-good committed baseline.

What may differ on iPhone:
- Local network permission prompts
- Wi-Fi interface and routing behavior
- iPhone-only socket timing differences
- App lifecycle differences vs simulator

Practical expectation:
- Low-to-moderate chance of a rebuild-only regression in the native transport
- Moderate chance of a device-specific runtime or networking issue

## Debugging Tools If iPhone Build Fails

Available tools:

- Xcode device console
  - Best first place to watch live app logs while reproducing the problem on the iPhone.

- Native app log file
  - The app writes native debug information to `ic705-debug.log` inside the app container.

- Direct Swift reference script on the Mac
  - Confirms whether the radio/network path is healthy independent of the app.

- `refreshStatus()` direct radio query
  - Useful to separate direct-session success from persistent-session problems.

Recommended debug flow:
1. Confirm the standalone Swift script still talks to the radio from the Mac.
2. Run the app from Xcode on the iPhone and watch the device logs.
3. Check whether `connect` succeeds.
4. Check whether CI-V replies are missing or whether session setup itself fails.
5. Pull the app log file if needed.

## Swift Scripts

The standalone Swift scripts are **not** deployed to the iPhone as part of the app build.

They are Mac-side development tools.

Example script:
- [../IC705RigControl/rig-control-script.swift](/Users/keithwillard/projects/iphone_dev/IC705RigControl/rig-control-script.swift)

They run on the Mac from Terminal, not on the iPhone.

Example commands:

```bash
swift /Users/keithwillard/projects/iphone_dev/IC705RigControl/rig-control-script.swift 192.168.59.1 kew qwerty12345 freq
swift /Users/keithwillard/projects/iphone_dev/IC705RigControl/rig-control-script.swift 192.168.59.1 kew qwerty12345 mode
swift /Users/keithwillard/projects/iphone_dev/IC705RigControl/rig-control-script.swift 192.168.59.1 kew qwerty12345 cw 'AC00VW?'
```

Relationship between app and scripts:
- The iPhone deployment installs only the app.
- The Swift script remains on the Mac as a reference/debug harness.

If the script logic were ever needed on the phone, it would have to be compiled into the app as native code. That is not how it is currently set up.
