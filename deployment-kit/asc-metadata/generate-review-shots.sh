#!/usr/bin/env bash
# Build phone-sized App Review screenshots (1242×2688 JPG) from 1024 promo PNGs.
# ASC rejects 1024×1024 for the review-screenshot slot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ASSETS="$ROOT/docs/store-assets"
OUT="$ASSETS/review"
mkdir -p "$OUT"

if ! command -v magick >/dev/null 2>&1; then
  echo "magick (ImageMagick) required to generate review screenshots" >&2
  exit 1
fi

for stem in plus-monthly plus-annual pro-monthly pro-annual studio-monthly studio-annual; do
  src="$ASSETS/${stem}-1024.png"
  dst="$OUT/${stem}.jpg"
  if [[ ! -f "$src" ]]; then
    echo "skip missing $src"
    continue
  fi
  magick "$src" \
    -background '#16101C' -gravity center -extent 1242x2688 \
    -flatten -alpha off -quality 90 \
    "$dst"
  echo "wrote $dst"
done
