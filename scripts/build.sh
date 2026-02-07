#!/usr/bin/env sh
set -eu

if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
  cat <<'EOF'
Usage: scripts/build.sh [zig build args...]

Environment:
  ZIG_BIN               Path to zig binary (default: zig)
  ZIG_GLOBAL_CACHE_DIR  Global cache dir (default: /tmp/zicro-zig-global-cache)
  ZIG_LOCAL_CACHE_DIR   Local cache dir (default: ./.zig-cache)
EOF
  exit 0
fi

ZIG_BIN="${ZIG_BIN:-zig}"
ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/zicro-zig-global-cache}"
ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-.zig-cache}"

if ! command -v "$ZIG_BIN" >/dev/null 2>&1; then
  echo "error: zig not found: $ZIG_BIN" >&2
  exit 1
fi

ZIG_VERSION="$("$ZIG_BIN" version)"
MAJOR="$(printf "%s" "$ZIG_VERSION" | cut -d. -f1 | sed 's/[^0-9].*$//')"
MINOR="$(printf "%s" "$ZIG_VERSION" | cut -d. -f2 | sed 's/[^0-9].*$//')"
PATCH="$(printf "%s" "$ZIG_VERSION" | cut -d. -f3 | sed 's/[^0-9].*$//')"
MAJOR="${MAJOR:-0}"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

if [ "$MAJOR" -lt 0 ] || { [ "$MAJOR" -eq 0 ] && [ "$MINOR" -lt 15 ]; } || { [ "$MAJOR" -eq 0 ] && [ "$MINOR" -eq 15 ] && [ "$PATCH" -lt 2 ]; }; then
  echo "error: Zig 0.15.2+ required, found $ZIG_VERSION" >&2
  exit 1
fi

mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
exec "$ZIG_BIN" build \
  --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
  --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
  "$@"
