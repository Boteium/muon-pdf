#!/usr/bin/env bash
set -euo pipefail

APP="muon-pdf"
DESKTOP_FILE="muon-pdf.desktop"

PREFIX="${PREFIX:-/usr}"
BINDIR="${BINDIR:-$PREFIX/bin}"
APPDIR="${APPDIR:-$PREFIX/share/applications}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$SCRIPT_DIR/$APP"
DESKTOP_SRC="$SCRIPT_DIR/$DESKTOP_FILE"

if [[ ! -f "$BIN_SRC" ]]; then
  echo "error: missing $APP next to install.sh"
  exit 1
fi

if [[ ! -f "$DESKTOP_SRC" ]]; then
  echo "error: missing $DESKTOP_FILE next to install.sh"
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo PREFIX="$PREFIX" BINDIR="$BINDIR" APPDIR="$APPDIR" bash "$0" "$@"
  fi
  echo "error: run as root or install sudo"
  exit 1
fi

install -Dm755 "$BIN_SRC" "$BINDIR/$APP"
install -Dm644 "$DESKTOP_SRC" "$APPDIR/$DESKTOP_FILE"

echo "Installed:"
echo "  $BINDIR/$APP"
echo "  $APPDIR/$DESKTOP_FILE"
