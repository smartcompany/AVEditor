#!/usr/bin/env bash
# Prepare ASC review-submission draft for first subscription review
# (group + all subscription versions + retention + app version when ready).
#
# Usage:
#   ./prepare-subscription-review.sh --dry-run
#   ./prepare-subscription-review.sh
#   ./prepare-subscription-review.sh --submit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$SCRIPT_DIR"

APP_CONFIG="$KIT_DIR/app-config.json"
read_config() {
  node -e "const c=require(process.argv[1]); console.log(c[process.argv[2]]??'');" "$APP_CONFIG" "$1" 2>/dev/null || true
}

export ASC_KEY_ID="${ASC_KEY_ID:-$(read_config ascKeyId)}"
export ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-$(read_config ascKeyPath)}"
export ASC_BUNDLE_ID="${ASC_BUNDLE_ID:-$(read_config bundleId)}"

SHOT_DIR="$ROOT/docs/store-assets/app-screenshots"
mkdir -p "$SHOT_DIR"
if command -v magick >/dev/null 2>&1; then
  SRC="$ROOT/docs/store-assets/review/plus-monthly.jpg"
  if [[ -f "$SRC" ]]; then
    # 6.7" / Dynamic Island class sizes Apple commonly accepts
    magick "$SRC" -resize 1290x2796^ -gravity center -extent 1290x2796 -quality 90 \
      "$SHOT_DIR/iphone-6-7.png"
    magick "$SRC" -resize 1320x2868^ -gravity center -extent 1320x2868 -quality 90 \
      "$SHOT_DIR/iphone-6-9.png"
  fi
fi

exec node "$SCRIPT_DIR/prepare-subscription-review.mjs" "$@"
