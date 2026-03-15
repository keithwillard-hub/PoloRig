#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

APP_BUNDLE_ID="com.ac0vw.polorig.dev" \
METRO_PORT="8082" \
IOS_MODE="DevDebug" \
IOS_BUILD_FOLDER="${ROOT_DIR}/ios/build/devdebug" \
IOS_EXTRA_PARAMS="RCT_METRO_PORT=8082" \
"${ROOT_DIR}/start_polorig.sh"
