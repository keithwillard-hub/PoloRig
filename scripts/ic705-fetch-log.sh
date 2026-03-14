#!/bin/bash

set -euo pipefail

DEVICE_ID="${DEVICE_ID:-99FB3D26-968C-448E-8395-349D8876EBDA}"
BUNDLE_ID="${BUNDLE_ID:-com.ac0vw.polorig.prod}"

APP_INFO="$(xcrun simctl listapps "$DEVICE_ID" | awk "/$BUNDLE_ID/ {flag=1} flag{print} /SBAppTags/ {flag=0}")"
DATA_URL="$(printf '%s\n' "$APP_INFO" | awk -F'"' '/DataContainer/ {print $2}')"

if [[ -z "$DATA_URL" ]]; then
  echo "Could not locate DataContainer for $BUNDLE_ID" >&2
  exit 1
fi

DATA_PATH="${DATA_URL#file://}"
LOG_PATH="$DATA_PATH/Library/Caches/ic705-debug.log"

if [[ ! -f "$LOG_PATH" ]]; then
  echo "No debug log found at $LOG_PATH" >&2
  exit 1
fi

echo "$LOG_PATH"
tail -n 200 "$LOG_PATH"
