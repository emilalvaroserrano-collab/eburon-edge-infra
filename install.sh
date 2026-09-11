#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO="emilalvaroserrano-collab/eburon-edge-infra"
RELEASE_REF="${EBURON_RELEASE_REF:-436b4c469bd31701919d178b9e378db328d4dd26}"
VERSION="v0.3.0"
PACKAGE="eburon-edge-termux-arm64-${VERSION}.zip"
PACKAGE_SHA256="ac755db33358a1f4db4f7fe10afb96d3d3c2292aa00ab22754cbea4d78007fd2"
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
info(){ printf '\033[36m%s\033[0m\n' "$*"; }

case "${PREFIX:-}" in
  *com.termux*) ;;
  *) fail 'Run this inside Termux.' ;;
esac

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) fail "This release targets Android ARM64 only. Detected: $(uname -m)" ;;
esac

info "Eburon Edge ${VERSION} — one-command installer"
info "Internet is required only for initial provisioning."

pkg install -y curl unzip coreutils >/dev/null

BASE="https://raw.githubusercontent.com/${REPO}/${RELEASE_REF}/dist"
info "Downloading ${PACKAGE}…"
curl -fLsS --retry 6 --retry-delay 2 --retry-all-errors \
  "$BASE/$PACKAGE" -o "$TMP/$PACKAGE"

printf '%s  %s\n' "$PACKAGE_SHA256" "$TMP/$PACKAGE" | sha256sum -c - >/dev/null \
  || fail 'Release package integrity check failed.'
info 'Package integrity verified.'

unzip -q "$TMP/$PACKAGE" -d "$TMP/payload"
PAYLOAD="$TMP/payload/eburon-edge-termux/install.sh"
[ -s "$PAYLOAD" ] || fail 'Payload installer missing.'
chmod +x "$PAYLOAD"

EBURON_PACKAGE_REF="$RELEASE_REF" \
EBURON_VERSION="$VERSION" \
EBURON_ROOT="$ROOT" \
  bash "$PAYLOAD"
