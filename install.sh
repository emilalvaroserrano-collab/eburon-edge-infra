#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
REPO="emilalvaroserrano-collab/eburon-edge-infra"
REF="${EBURON_RELEASE_REF:-main}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
case "${PREFIX:-}" in *com.termux*) ;; *) echo 'Run this inside Termux.' >&2; exit 1;; esac
case "$(uname -m)" in aarch64|arm64) ;; *) echo 'Android ARM64 only.' >&2; exit 1;; esac
pkg install -y curl unzip coreutils >/dev/null
BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
VERSION="$(curl -fLsS --retry 6 "$BASE/VERSION" | tr -d '\r\n')"
PKG="eburon-edge-termux-arm64-${VERSION}.zip"
curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors "$BASE/dist/$PKG" -o "$TMP/$PKG"
curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors "$BASE/dist/SHA256SUMS" -o "$TMP/SHA256SUMS"
(cd "$TMP" && grep "  $PKG$" SHA256SUMS | sha256sum -c -)
unzip -q "$TMP/$PKG" -d "$TMP/payload"
EBURON_PACKAGE_REF="$REF" bash "$TMP/payload/eburon-edge-termux/install.sh"
