#!/usr/bin/env bash
# Set ASC subscription groupLevel (Studio=1, Pro=2, Plus=3).
#
# Usage:
#   ./set-subscription-levels.sh
#   ./set-subscription-levels.sh --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

APP_CONFIG="$KIT_DIR/app-config.json"
read_config() {
  node -e "const c=require(process.argv[1]); console.log(c[process.argv[2]]??'');" "$APP_CONFIG" "$1" 2>/dev/null || true
}

export ASC_KEY_ID="${ASC_KEY_ID:-$(read_config ascKeyId)}"
export ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-$(read_config ascKeyPath)}"
export ASC_BUNDLE_ID="${ASC_BUNDLE_ID:-$(read_config bundleId)}"

exec node "$SCRIPT_DIR/set-subscription-levels.mjs" "$@"
