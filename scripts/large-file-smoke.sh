#!/usr/bin/env sh
set -eu

if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
  cat <<'EOF'
Usage: scripts/large-file-smoke.sh [size_mb] [output_path] [--open]

Examples:
  scripts/large-file-smoke.sh
  scripts/large-file-smoke.sh 128 /tmp/zicro-large-128mb.ts
  scripts/large-file-smoke.sh 192 /tmp/zicro-large-192mb.ts --open
EOF
  exit 0
fi

SIZE_MB="${1:-128}"
OUT="${2:-/tmp/zicro-large-${SIZE_MB}mb.ts}"
OPEN_FLAG="${3:-}"

case "$SIZE_MB" in
  ''|*[!0-9]*)
    echo "error: size_mb must be a positive integer" >&2
    exit 1
    ;;
esac

if [ "$SIZE_MB" -lt 100 ]; then
  echo "error: size_mb must be >= 100 for large-file smoke test" >&2
  exit 1
fi

TARGET_BYTES=$((SIZE_MB * 1024 * 1024))
LINE='export const payload = "abcdefghijklmnopqrstuvwxyz0123456789"; // zicro large-file smoke'
LINE_BYTES=$(( ${#LINE} + 1 ))
LINE_COUNT=$(( TARGET_BYTES / LINE_BYTES + 1 ))

yes "$LINE" | head -n "$LINE_COUNT" > "$OUT"

ACTUAL_BYTES="$(wc -c < "$OUT" | tr -d ' ')"
echo "Generated: $OUT (${ACTUAL_BYTES} bytes)"
echo "Smoke flow:"
echo "  1) ./zig-out/bin/zicro \"$OUT\""
echo "  2) Ctrl+F -> type payload -> verify centered match and smooth next/prev with Up/Down"
echo "  3) Scroll, edit, save, quit"
echo "Tip: for pure editor perf test set \"lsp.enabled\": false in .zicro.json"

if [ "$OPEN_FLAG" = "--open" ]; then
  exec ./zig-out/bin/zicro "$OUT"
fi

