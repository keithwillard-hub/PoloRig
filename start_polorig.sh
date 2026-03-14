#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.ac0vw.polorig.prod}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
METRO_PORT="${METRO_PORT:-8081}"
METRO_LOG="${ROOT_DIR}/tmp/metro-start.log"
ENVFILE="${ENVFILE:-.env.local}"

ensure_tmp_dir() {
  mkdir -p "${ROOT_DIR}/tmp"
}

ensure_metro() {
  if lsof -iTCP:"${METRO_PORT}" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
    echo "Metro already running on :${METRO_PORT}"
    return
  fi

  echo "Starting Metro on :${METRO_PORT}"
  ensure_tmp_dir
  (
    cd "${ROOT_DIR}"
    nohup npx react-native start --port "${METRO_PORT}" > "${METRO_LOG}" 2>&1 &
  )

  local attempts=0
  while ! lsof -iTCP:"${METRO_PORT}" -sTCP:LISTEN -n -P >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [[ "${attempts}" -ge 30 ]]; then
      echo "Metro did not start. Check ${METRO_LOG}" >&2
      exit 1
    fi
    sleep 1
  done

  echo "Metro is running"
}

ensure_simulator() {
  open -a Simulator >/dev/null 2>&1 || true

  if xcrun simctl list devices booted | rg -q "Booted"; then
    echo "Simulator already booted"
  else
    echo "Booting simulator: ${SIMULATOR_NAME}"
    xcrun simctl boot "${SIMULATOR_NAME}" >/dev/null 2>&1 || true
  fi

  xcrun simctl bootstatus booted -b
}

launch_app() {
  echo "Launching ${APP_BUNDLE_ID}"

  if ! xcrun simctl launch booted "${APP_BUNDLE_ID}" >/dev/null 2>&1; then
    echo "App is not installed in the booted simulator. Building/installing it now with ${ENVFILE}."
    (
      cd "${ROOT_DIR}"
      ENVFILE="${ENVFILE}" npx react-native run-ios --simulator "${SIMULATOR_NAME}" --no-packager
    )

    if ! xcrun simctl launch booted "${APP_BUNDLE_ID}" >/dev/null 2>&1; then
      echo "App build/install completed, but launch still failed for ${APP_BUNDLE_ID}." >&2
      exit 1
    fi
  fi

  echo "App launched"
}

ensure_metro
ensure_simulator
launch_app
