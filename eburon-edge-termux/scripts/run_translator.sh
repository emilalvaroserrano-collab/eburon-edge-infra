#!/usr/bin/env bash
set -euo pipefail
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
source "$ROOT/config/eburon.env"
PORT="${EBURON_TRANSLATOR_PORT:-8851}"
command -v deno >/dev/null || { echo 'ERROR: deno not installed' >&2; exit 1; }
exec deno run --no-config --quiet \
  --allow-env \
  --allow-read="$ROOT/translator,$ROOT/models/m2m100-local" \
  --allow-net="127.0.0.1:$PORT" \
  "$ROOT/translator/server.mjs"
