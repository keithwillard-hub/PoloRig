#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

APP_BUNDLE_ID="com.ac0vw.polorig.prod" \
METRO_PORT="8081" \
METRO_PID_FILE="${ROOT_DIR}/tmp/metro-8081.pid" \
"${ROOT_DIR}/stop_polorig.sh"
