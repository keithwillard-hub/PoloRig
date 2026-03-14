#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACE_ROOT="$ROOT_DIR/tmp/ic705-traces"
PID_FILE="$TRACE_ROOT/current.pid"
SESSION_FILE="$TRACE_ROOT/current.session"
DEFAULT_BUNDLE_ID="${BUNDLE_ID:-com.ac0vw.polorig.dev}"
DEFAULT_APP_NAME="${APP_NAME:-PoloRig}"

mkdir -p "$TRACE_ROOT"

usage() {
  cat <<EOF
Usage:
  scripts/ic705-trace.sh start [bundle_id]
  scripts/ic705-trace.sh launch [bundle_id]
  scripts/ic705-trace.sh capture [bundle_id]
  scripts/ic705-trace.sh stop
  scripts/ic705-trace.sh status

Commands:
  start    Start a filtered simulator log stream in the foreground.
  launch   Launch the app in the booted simulator.
  capture  Start logging in the background and launch the app.
  stop     Stop the background capture session.
  status   Show the current capture session location.
EOF
}

require_booted_simulator() {
  if ! xcrun simctl list devices booted | grep -q "Booted"; then
    echo "No booted simulator found." >&2
    exit 1
  fi
}

resolve_bundle_id() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    echo "$1"
  else
    echo "$DEFAULT_BUNDLE_ID"
  fi
}

predicate() {
  cat <<'EOF'
subsystem == "com.ac0vw.polorig" OR
subsystem == "com.ic705cwlogger" OR
process == "PoloRig" OR
eventMessage CONTAINS[c] "IC705"
EOF
}

start_foreground() {
  local bundle_id="$1"
  local session_id
  session_id="$(date +%Y%m%d-%H%M%S)"
  local session_dir="$TRACE_ROOT/$session_id"
  local log_file="$session_dir/simulator.log"
  mkdir -p "$session_dir"

  cat > "$session_dir/metadata.txt" <<EOF
session_id=$session_id
bundle_id=$bundle_id
started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
predicate=$(predicate | tr '\n' ' ')
EOF

  echo "$session_dir" > "$SESSION_FILE"
  echo "Writing filtered simulator logs to:"
  echo "  $log_file"
  echo
  echo "Launch the app and reproduce the issue. Press Ctrl-C to stop."

  xcrun simctl spawn booted log stream \
    --style compact \
    --level debug \
    --predicate "$(predicate)" | tee "$log_file"
}

start_background() {
  local bundle_id="$1"
  local session_id
  session_id="$(date +%Y%m%d-%H%M%S)"
  local session_dir="$TRACE_ROOT/$session_id"
  local log_file="$session_dir/simulator.log"
  mkdir -p "$session_dir"

  cat > "$session_dir/metadata.txt" <<EOF
session_id=$session_id
bundle_id=$bundle_id
started_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
predicate=$(predicate | tr '\n' ' ')
EOF

  nohup xcrun simctl spawn booted log stream \
    --style compact \
    --level debug \
    --predicate "$(predicate)" > "$log_file" 2>&1 < /dev/null &

  echo "$!" > "$PID_FILE"
  echo "$session_dir" > "$SESSION_FILE"
  echo "Background trace capture started:"
  echo "  PID: $(cat "$PID_FILE")"
  echo "  Session: $session_dir"
  echo "  Log: $log_file"
}

stop_background() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "No background trace session is currently running."
    return
  fi

  local pid
  pid="$(cat "$PID_FILE")"
  if kill "$pid" >/dev/null 2>&1; then
    echo "Stopped trace session PID $pid"
  else
    echo "Trace session PID $pid was not running."
  fi
  rm -f "$PID_FILE"
}

show_status() {
  if [[ -f "$SESSION_FILE" ]]; then
    local session_dir
    session_dir="$(cat "$SESSION_FILE")"
    echo "Current session: $session_dir"
    if [[ -f "$PID_FILE" ]]; then
      echo "Background PID: $(cat "$PID_FILE")"
    fi
    if [[ -f "$session_dir/simulator.log" ]]; then
      echo "Log file: $session_dir/simulator.log"
    fi
  else
    echo "No trace session recorded."
  fi
}

launch_app() {
  local bundle_id="$1"
  require_booted_simulator
  xcrun simctl launch booted "$bundle_id"
}

cmd="${1:-}"
case "$cmd" in
  start)
    shift || true
    require_booted_simulator
    start_foreground "$(resolve_bundle_id "$@")"
    ;;
  launch)
    shift || true
    launch_app "$(resolve_bundle_id "$@")"
    ;;
  capture)
    shift || true
    local_bundle_id="$(resolve_bundle_id "$@")"
    require_booted_simulator
    start_background "$local_bundle_id"
    launch_app "$local_bundle_id"
    ;;
  stop)
    stop_background
    ;;
  status)
    show_status
    ;;
  *)
    usage
    exit 1
    ;;
esac
