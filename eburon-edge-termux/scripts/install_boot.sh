#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}";BOOT="$HOME/.termux/boot";mkdir -p "$BOOT";printf '#!/data/data/com.termux/files/usr/bin/bash\nsleep 8\nEBURON_ROOT="%s" "%s/start.sh" >>"%s/logs/boot.log" 2>&1 || true\n' "$ROOT" "$ROOT" "$ROOT">"$BOOT/eburon-edge.sh";chmod +x "$BOOT/eburon-edge.sh"
