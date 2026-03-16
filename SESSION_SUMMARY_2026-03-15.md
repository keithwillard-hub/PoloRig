# Session Summary

Date: 2026-03-15
Repo: `/Users/keithwillard/projects/iphone_dev/PoloRig`

## What You Asked Me To Do

During this session, you asked me to:

- Kill any background Metro bundler processes.
- Start the current `PoloRig` app.
- Fix the `No script URL provided` startup issue.
- Patch the startup flow so Metro failures are detected before the app launches.
- Investigate the IC-705 settings issue where the app claimed rig control was only available on iOS.
- Commit and push selected fixes to `main` without disturbing in-progress feature branch work.
- Set up separate launch flows for `main` and feature worktrees so Metro/app runs do not cross-contaminate.
- Add matching shutdown scripts and make them shut down the app, Metro, and the simulator.
- Launch and shut down `main` and feature builds on demand for testing.
- Diagnose and fix the feature-branch iOS build failure.
- Rename the separate simulator installs so `main` and feature builds are visually distinguishable.
- Provide a written summary of the session.

## What Was Accomplished

### Process and launch management

- Killed existing Metro processes multiple times and verified when they were gone.
- Added startup hardening so Metro readiness is checked before launching the app.
- Added separate start scripts for isolated `prod` and `dev` launches.
- Added separate stop scripts for isolated `prod` and `dev` shutdown.
- Updated stop scripts so they shut down:
  - the app
  - the matching Metro process
  - the booted simulator

### Branch/worktree isolation

- Kept the feature checkout intact.
- Created and used a separate `main` worktree at `/tmp/PoloRig-main`.
- Established the intended split:
  - `main` / prod app: `com.ac0vw.polorig.prod`, Metro `8081`
  - feature / dev app: `com.ac0vw.polorig.dev`, Metro `8082`

### Commits made on `main`

- `4200580` `Harden Metro startup and IC705 module lookup`
- `348c1bd` `Add isolated prod and dev launchers`
- `8fd092c` `Add prod and dev shutdown scripts`
- `5ffba92` `Shut down simulator in stop scripts`

### Feature branch commit/push

- Committed and pushed on `feature/ic705-session-manager`:
  - `63bd5b8` `Add isolated launch and shutdown scripts`

### IC-705 and native module work

- Updated [`src/native/IC705RigControl.js`](/Users/keithwillard/projects/iphone_dev/PoloRig/src/native/IC705RigControl.js) to resolve the native module via `TurboModuleRegistry` instead of only `NativeModules`.
- Rebuilt and relaunched to test whether that fixed the false “only available on iOS” message.
- That issue was not fully confirmed resolved from the simulator testing done in this session.

### Feature branch iOS build failure

- Diagnosed the feature `DevDebug` build failure down to the actual linker error.
- Identified missing Hermes inspector symbols required by `RNWorklets` / Reanimated:
  - `facebook::hermes::inspector_modern::chrome::enableDebugging(...)`
  - `facebook::hermes::inspector_modern::chrome::disableDebugging(int)`
- Patched [`ios/Podfile`](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/Podfile) so `React-hermes` debug builds compile with `HERMES_ENABLE_DEBUGGER=1`.
- Re-ran `pod install` and rebuilt successfully past the earlier linker failure.

### App naming / Xcode config cleanup

- Patched [`ios/polorig.xcodeproj/project.pbxproj`](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig.xcodeproj/project.pbxproj) to set display names intended to be:
  - `PoloRig Main`
  - `PoloRig Feature`
- Also corrected an Xcode configuration issue where `ProdDebug` was incorrectly using the dev bundle identifier instead of the prod bundle identifier.

## What Is Still Not Resolved

### Feature app startup crash

The feature app still crashes on startup.

Current verified failure:

- React Native fatal during bundle load
- `No script URL provided`
- `unsanitizedScriptURLString = (null)`

What this means:

- Metro being alive on `8082` is not enough by itself.
- The feature build is still starting React Native without any usable JS bundle URL.
- The current failure is no longer the Hermes/Reanimated linker problem.

### Display names not yet visually verified

- The Xcode project settings for `PoloRig Main` and `PoloRig Feature` were patched.
- You reported the simulator icons still did not show distinct labels yet.
- That means the label change still needs to be verified with clean rebuild/reinstall flows.

## What I Tried On The Crash Path

I already tried and ruled out these higher-level causes:

- Metro simply not running
- the earlier Hermes linker issue
- missing `DEBUG` configuration in `DevDebug`
- simple AppDelegate bundle URL override attempts
- simple React Native factory/root-view override attempts

Current working conclusion:

- The remaining bug is likely deeper in the React Native 0.83 bridgeless iOS startup path.
- The bundle URL appears to be dropped or never supplied before bundle loading begins.

## Current Source State

Files changed during the later debugging round include:

- [`ios/Podfile`](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/Podfile)
- [`ios/polorig/AppDelegate.swift`](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig/AppDelegate.swift)
- [`ios/polorig.xcodeproj/project.pbxproj`](/Users/keithwillard/projects/iphone_dev/PoloRig/ios/polorig.xcodeproj/project.pbxproj)

Other previously changed files from this session include:

- [`start_polorig.sh`](/Users/keithwillard/projects/iphone_dev/PoloRig/start_polorig.sh)
- [`start_polorig_prod.sh`](/Users/keithwillard/projects/iphone_dev/PoloRig/start_polorig_prod.sh)
- [`start_polorig_dev.sh`](/Users/keithwillard/projects/iphone_dev/PoloRig/start_polorig_dev.sh)
- [`stop_polorig.sh`](/Users/keithwillard/projects/iphone_dev/PoloRig/stop_polorig.sh)
- [`stop_polorig_prod.sh`](/Users/keithwillard/projects/iphone_dev/PoloRig/stop_polorig_prod.sh)
- [`stop_polorig_dev.sh`](/Users/keithwillard/projects/iphone_dev/PoloRig/stop_polorig_dev.sh)
- [`package.json`](/Users/keithwillard/projects/iphone_dev/PoloRig/package.json)
- [`src/native/IC705RigControl.js`](/Users/keithwillard/projects/iphone_dev/PoloRig/src/native/IC705RigControl.js)

## Where Things Stand Right Now

- `main` branch operational changes were committed and pushed.
- Feature branch launcher/shutdown changes were committed and pushed.
- The feature iOS linker failure was fixed.
- The feature app still does not launch successfully because of the React Native nil bundle URL startup crash.
- The `main` and feature simulator labels were patched in source but not yet fully verified visually after rebuild/reinstall.
- Background process state may have changed since the last live check; treat runtime state as needing fresh verification before the next launch attempt.

## Recommended Next Steps

1. Re-check and clean current runtime state:
   - simulator
   - Metro on `8081`
   - Metro on `8082`
2. Continue tracing the React Native 0.83 bridgeless iOS startup path for the feature build until the bundle URL source is identified.
3. Relaunch the feature app after that fix and verify the crash is gone.
4. Rebuild/reinstall both prod and dev apps to confirm the labels appear as `PoloRig Main` and `PoloRig Feature`.
