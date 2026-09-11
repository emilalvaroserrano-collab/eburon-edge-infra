#!/data/data/com.termux/files/usr/bin/bash
set -u
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
for file in "$ROOT"/run/*.pid; do
  [ -f "$file" ] || continue
  pid="$(cat "$file" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$file"
done
command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock || true
