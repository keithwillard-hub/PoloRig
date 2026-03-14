# IC-705 Trace Workflow

Use this when reproducing IC-705 connect/CW issues in the iOS simulator.

## What it captures

- Native IC-705 transport logs from:
  - `com.ac0vw.polorig`
  - `com.ic705cwlogger`
- Automatic UI trace markers for:
  - connect / disconnect taps
  - callsign commit from the logging screen
  - manual CW button taps
  - auto-CW requests on lookup miss

## Start a capture session

From the repo root:

```bash
npm run ic705:capture
```

That will:

1. Start a filtered simulator log stream in the background
2. Create a timestamped session folder under `tmp/ic705-traces/`
3. Launch `com.ac0vw.polorig.dev` in the booted simulator

## Check session location

```bash
./scripts/ic705-trace.sh status
```

## Stop background capture

```bash
npm run ic705:trace:stop
```

## Foreground mode

If you want to watch logs live in the terminal:

```bash
npm run ic705:trace
```

Then launch the app manually or with:

```bash
npm run ic705:launch
```
