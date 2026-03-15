#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

APP_BUNDLE_ID="com.ac0vw.polorig.dev" \
METRO_PORT="8082" \
METRO_PID_FILE="${ROOT_DIR}/tmp/metro-8082.pid" \
"${ROOT_DIR}/stop_polorig.sh"
