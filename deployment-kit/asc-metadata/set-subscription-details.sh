#!/usr/bin/env bash
# Fill ASC subscription detail pages (availability, prices, locs, images).
#
# Usage:
#   ./set-subscription-details.sh --dry-run
#   ./set-subscription-details.sh
#   ./set-subscription-details.sh --only localizations,promo
#   ./set-subscription-details.sh --product com.smartcompany.aveditor.studio.annual

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

# Ensure phone-sized review JPGs exist (1024 promo ≠ review screenshot).
need_shots=1
prev=""
for a in "$@"; do
  if [[ "$prev" == "--only" && "$a" != *promo* && "$a" != *review* ]]; then
    need_shots=0
  fi
  prev="$a"
done
if [[ "$need_shots" == "1" ]]; then
  "$SCRIPT_DIR/generate-review-shots.sh"
fi

exec node "$SCRIPT_DIR/set-subscription-details.mjs" "$@"
