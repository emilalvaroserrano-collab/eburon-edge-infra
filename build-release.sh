#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(tr -d '\r\n' < "$HERE/VERSION")"
PACKAGE="eburon-edge-termux-arm64-${VERSION}.zip"
find "$HERE/eburon-edge-termux" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
find "$HERE/eburon-edge-termux" -type f -name '*.pyc' -delete
mkdir -p "$HERE/dist"
rm -f "$HERE/dist/$PACKAGE"
(cd "$HERE" && zip -X -qr "dist/$PACKAGE" eburon-edge-termux -x '*/__pycache__/*' '*.pyc')
SHA="$(sha256sum "$HERE/dist/$PACKAGE" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$PACKAGE" > "$HERE/dist/SHA256SUMS"
echo "$PACKAGE"
echo "$SHA"
