#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
ROOT="${EBURON_ROOT:-$HOME/.eburon-edge}"
REV="927cfce34f31707e17f2bff35c349632fb9e2c3a"
SRC="$ROOT/src/whisper.cpp"
BIN="$ROOT/bin"
mkdir -p "$ROOT/src" "$BIN"
if [ -x "$BIN/whisper-server" ] && [ -x "$BIN/whisper-cli" ] && [ -f "$ROOT/.whisper-rev" ] && grep -qx "$REV" "$ROOT/.whisper-rev"; then
  echo '  ✓ whisper.cpp pinned binary already present'
  exit 0
fi
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
[ "$JOBS" -gt 6 ] && JOBS=6
rm -rf "$SRC"
git clone -q --filter=blob:none --no-checkout https://github.com/ggml-org/whisper.cpp.git "$SRC"
git -C "$SRC" fetch -q --depth=1 origin "$REV"
git -C "$SRC" reset -q --hard FETCH_HEAD
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DWHISPER_SDL2=OFF -DGGML_OPENMP=OFF >/dev/null
cmake --build "$SRC/build" -j "$JOBS" --target whisper-server whisper-cli >/dev/null
install -m755 "$SRC/build/bin/whisper-server" "$BIN/whisper-server.new"
install -m755 "$SRC/build/bin/whisper-cli" "$BIN/whisper-cli.new"
mv -f "$BIN/whisper-server.new" "$BIN/whisper-server"
mv -f "$BIN/whisper-cli.new" "$BIN/whisper-cli"
echo "$REV">"$ROOT/.whisper-rev"
echo "  ✓ whisper.cpp built and pinned ($JOBS build jobs)"
