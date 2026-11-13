#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Scripts live in deployment-kit/ (not deployment-kit/scripts/)
KIT_DIR="$SCRIPT_DIR"

exec "$KIT_DIR/play-metadata/update-metadata.sh" "$@"
