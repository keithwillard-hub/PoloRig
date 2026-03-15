#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

APP_BUNDLE_ID="com.ac0vw.polorig.prod" \
METRO_PORT="8081" \
IOS_MODE="ProdDebug" \
IOS_BUILD_FOLDER="${ROOT_DIR}/ios/build/proddebug" \
IOS_EXTRA_PARAMS="RCT_METRO_PORT=8081" \
"${ROOT_DIR}/start_polorig.sh"
