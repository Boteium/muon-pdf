#!/usr/bin/env bash
set -euo pipefail

APP="muon-pdf"
DESKTOP_FILE="muon-pdf.desktop"

PREFIX="${PREFIX:-/usr}"
BINDIR="${BINDIR:-$PREFIX/bin}"
APPDIR="${APPDIR:-$PREFIX/share/applications}"

if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo PREFIX="$PREFIX" BINDIR="$BINDIR" APPDIR="$APPDIR" bash "$0" "$@"
  fi
  echo "error: run as root or install sudo"
  exit 1
fi

rm -f "$BINDIR/$APP"
rm -f "$APPDIR/$DESKTOP_FILE"

echo "Removed (if present):"
echo "  $BINDIR/$APP"
echo "  $APPDIR/$DESKTOP_FILE"
