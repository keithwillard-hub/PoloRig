#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.ac0vw.polorig.prod}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
METRO_PORT="${METRO_PORT:-8081}"
METRO_LOG="${METRO_LOG:-${ROOT_DIR}/tmp/metro-${METRO_PORT}.log}"
METRO_PID_FILE="${METRO_PID_FILE:-${ROOT_DIR}/tmp/metro-${METRO_PORT}.pid}"
ENVFILE="${ENVFILE:-.env.local}"
IOS_MODE="${IOS_MODE:-}"
IOS_SCHEME="${IOS_SCHEME:-}"
IOS_BUILD_FOLDER="${IOS_BUILD_FOLDER:-}"
IOS_EXTRA_PARAMS="${IOS_EXTRA_PARAMS:-}"

ensure_tmp_dir() {
  mkdir -p "${ROOT_DIR}/tmp"
}

metro_status_ok() {
  curl -fsS "http://127.0.0.1:${METRO_PORT}/status" 2>/dev/null | rg -q "^packager-status:running$"
}

metro_bundle_ok() {
  curl -fsSI \
    "http://127.0.0.1:${METRO_PORT}/index.bundle?platform=ios&dev=true&lazy=true&minify=false&inlineSourceMap=false&modulesOnly=false&runModule=true&app=${APP_BUNDLE_ID}" \
    >/dev/null 2>&1
}

ensure_metro() {
  if lsof -iTCP:"${METRO_PORT}" -sTCP:LISTEN -n -P >/dev/null 2>&1 && metro_status_ok; then
    echo "Metro already running on :${METRO_PORT}"
    return
  fi

  echo "Starting Metro on :${METRO_PORT}"
  ensure_tmp_dir
  (
    cd "${ROOT_DIR}"
    nohup /bin/zsh -lc "exec npx react-native start --no-interactive --port '${METRO_PORT}'" \
      </dev/null > "${METRO_LOG}" 2>&1 &
    echo $! > "${METRO_PID_FILE}"
  )

  local attempts=0
  local metro_pid=""
  metro_pid="$(cat "${METRO_PID_FILE}" 2>/dev/null || true)"

  while true; do
    attempts=$((attempts + 1))
    if [[ -n "${metro_pid}" ]] && ! kill -0 "${metro_pid}" >/dev/null 2>&1; then
      echo "Metro exited before becoming ready. Check ${METRO_LOG}" >&2
      exit 1
    fi

    if lsof -iTCP:"${METRO_PORT}" -sTCP:LISTEN -n -P >/dev/null 2>&1 && metro_status_ok; then
      break
    fi

    if [[ "${attempts}" -ge 30 ]]; then
      echo "Metro did not become ready. Check ${METRO_LOG}" >&2
      exit 1
    fi
    sleep 1
  done

  echo "Metro is running and responding"
}

ensure_metro_bundle() {
  local attempts=0

  while true; do
    attempts=$((attempts + 1))
    if metro_bundle_ok; then
      echo "Metro bundle endpoint is reachable"
      return
    fi

    if [[ "${attempts}" -ge 30 ]]; then
      echo "Metro bundle endpoint did not become reachable on :${METRO_PORT}" >&2
      exit 1
    fi
    sleep 1
  done
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
      local run_ios_cmd=(npx react-native run-ios --simulator "${SIMULATOR_NAME}" --no-packager --port "${METRO_PORT}")
      if [[ -n "${IOS_MODE}" ]]; then
        run_ios_cmd+=(--mode "${IOS_MODE}")
      fi
      if [[ -n "${IOS_SCHEME}" ]]; then
        run_ios_cmd+=(--scheme "${IOS_SCHEME}")
      fi
      if [[ -n "${IOS_BUILD_FOLDER}" ]]; then
        run_ios_cmd+=(--buildFolder "${IOS_BUILD_FOLDER}")
      fi
      if [[ -n "${IOS_EXTRA_PARAMS}" ]]; then
        run_ios_cmd+=(--extra-params "${IOS_EXTRA_PARAMS}")
      fi
      ENVFILE="${ENVFILE}" "${run_ios_cmd[@]}"
    )

    if ! xcrun simctl launch booted "${APP_BUNDLE_ID}" >/dev/null 2>&1; then
      echo "App build/install completed, but launch still failed for ${APP_BUNDLE_ID}." >&2
      exit 1
    fi
  fi

  echo "App launched"
}

ensure_metro
ensure_metro_bundle
ensure_simulator
launch_app
