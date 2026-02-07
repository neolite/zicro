#!/usr/bin/env sh
set -eu

if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
  cat <<'EOF'
Usage: scripts/install.sh

Environment:
  PREFIX      Install prefix (default: $HOME/.local)
  ZIG_BIN     Path to zig binary (default: zig)
EOF
  exit 0
fi

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *)
    echo "error: unsupported OS: $OS (expected Darwin or Linux)" >&2
    exit 1
    ;;
esac

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

"$SCRIPT_DIR/build.sh"

mkdir -p "$BIN_DIR"
install -m 0755 "$ROOT_DIR/zig-out/bin/zicro" "$BIN_DIR/zicro"

echo "Installed: $BIN_DIR/zicro"
echo "Add to PATH if needed: export PATH=\"$BIN_DIR:\$PATH\""

