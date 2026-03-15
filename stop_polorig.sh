#!/bin/zsh

set -euo pipefail

APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.ac0vw.polorig.prod}"
METRO_PORT="${METRO_PORT:-8081}"
METRO_PID_FILE="${METRO_PID_FILE:-}"
DISCONNECT_WAIT_SECONDS="${DISCONNECT_WAIT_SECONDS:-2}"

terminate_app() {
  echo "Terminating ${APP_BUNDLE_ID}"
  xcrun simctl terminate booted "${APP_BUNDLE_ID}" >/dev/null 2>&1 || true
}

kill_metro_by_pid_file() {
  if [[ -z "${METRO_PID_FILE}" || ! -f "${METRO_PID_FILE}" ]]; then
    return
  fi

  local metro_pid
  metro_pid="$(cat "${METRO_PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${metro_pid}" ]] && kill -0 "${metro_pid}" >/dev/null 2>&1; then
    echo "Stopping Metro pid ${metro_pid}"
    kill "${metro_pid}" >/dev/null 2>&1 || true
  fi
}

kill_metro_by_port() {
  local metro_pids
  metro_pids="$(lsof -tiTCP:"${METRO_PORT}" -sTCP:LISTEN -n -P 2>/dev/null || true)"
  if [[ -n "${metro_pids}" ]]; then
    echo "Stopping Metro on :${METRO_PORT}"
    kill ${=metro_pids} >/dev/null 2>&1 || true
  fi
}

terminate_app
sleep "${DISCONNECT_WAIT_SECONDS}"
kill_metro_by_pid_file
kill_metro_by_port

echo "Shutdown complete"
