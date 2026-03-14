#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/polorig-signaled-build}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
STATUS_DIR="$ROOT_DIR/tmp/build-status"
STATUS_FILE="$STATUS_DIR/ios-build-status.txt"
LOG_FILE="$STATUS_DIR/ios-build.log"
ENVFILE="${ENVFILE:-.env.local}"
BUNDLE_ID="${BUNDLE_ID:-com.ac0vw.polorig.prod}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/PoloRig.app"

mkdir -p "$STATUS_DIR"

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

booted_udid() {
  xcrun simctl list devices booted | awk -F '[()]' -v name="$SIMULATOR_NAME" '
    index($1, name) && $4 == "Booted" {
      print $2
      exit
    }
  '
}

STATUS_PREFIX=""
write_status() {
  local line="$1"
  STATUS_PREFIX+="$line"$'\n'
  printf "%s" "$STATUS_PREFIX" > "$STATUS_FILE"
  printf "%s\n" "$line"
}

write_status "STARTED $(timestamp) derivedData=$DERIVED_DATA_PATH simulator=$SIMULATOR_NAME envfile=$ENVFILE log=$LOG_FILE"

if ENVFILE="$ENVFILE" xcodebuild -quiet \
  -workspace "$ROOT_DIR/ios/polorig.xcworkspace" \
  -scheme polorig \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >"$LOG_FILE" 2>&1; then
  write_status "BUILD_DONE $(timestamp) derivedData=$DERIVED_DATA_PATH envfile=$ENVFILE app=$APP_PATH"
else
  write_status "BUILD_FAILED $(timestamp) derivedData=$DERIVED_DATA_PATH envfile=$ENVFILE log=$LOG_FILE"
  exit 1
fi

UDID="$(booted_udid)"
if [ -z "$UDID" ]; then
  write_status "INSTALL_SKIPPED $(timestamp) reason=no-booted-$SIMULATOR_NAME"
  exit 0
fi

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"
write_status "INSTALL_DONE $(timestamp) udid=$UDID app=$APP_PATH"

xcrun simctl launch --console "$UDID" "$BUNDLE_ID"
write_status "LAUNCH_DONE $(timestamp) udid=$UDID bundle=$BUNDLE_ID"
