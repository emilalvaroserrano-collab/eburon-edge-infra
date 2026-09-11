#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO="emilalvaroserrano-collab/eburon-edge-infra"
RELEASE_REF="${EBURON_RELEASE_REF:-e852a3e7163e69f5a13e99d68858ebe72ce47aae}"
VERSION="v0.3.1"
PACKAGE="eburon-edge-termux-arm64-${VERSION}.zip"
PACKAGE_SHA256="8722e11c59c8ff06168f2515cee74c030aa390fe1ffabf145c794d494c172e04"
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

# Termux splits the OpenSSL command-line binary into openssl-tool.
# The payload verifies npm tarball integrity with the `openssl` command,
# so install the CLI explicitly before the payload starts.
pkg install -y curl unzip coreutils openssl-tool >/dev/null
command -v openssl >/dev/null 2>&1 || fail 'Termux OpenSSL CLI is unavailable after installing openssl-tool.'

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
