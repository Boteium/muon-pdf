#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <x86_64|aarch64> <output-appimage-name>"
  exit 1
fi

ARCH="$1"
OUTPUT_NAME="$2"

case "$ARCH" in
  x86_64|aarch64) ;;
  *)
    echo "Unsupported architecture: $ARCH"
    echo "Expected one of: x86_64, aarch64"
    exit 1
    ;;
esac

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$ROOT_DIR/.appimage-build"
APPDIR="$WORK_DIR/AppDir"
APP_NAME="muon-pdf"
DESKTOP_FILE="$ROOT_DIR/muon-pdf.desktop"
BIN_FILE="$ROOT_DIR/zig-out/bin/$APP_NAME"
ICON_FILE="$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_NAME.png"

if [[ ! -f "$BIN_FILE" ]]; then
  echo "Missing built binary: $BIN_FILE"
  exit 1
fi

if [[ ! -f "$DESKTOP_FILE" ]]; then
  echo "Missing desktop file: $DESKTOP_FILE"
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$(dirname -- "$ICON_FILE")"

cp "$BIN_FILE" "$APPDIR/usr/bin/$APP_NAME"
cp "$DESKTOP_FILE" "$APPDIR/usr/share/applications/$APP_NAME.desktop"

if ! grep -q '^Icon=' "$APPDIR/usr/share/applications/$APP_NAME.desktop"; then
  printf '\nIcon=%s\n' "$APP_NAME" >> "$APPDIR/usr/share/applications/$APP_NAME.desktop"
fi

# 1x1 fallback icon keeps AppImage metadata valid.
printf 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=' | base64 -d > "$ICON_FILE"

pushd "$WORK_DIR" >/dev/null

echo "Downloading linuxdeploy ($ARCH)..."
wget -nv "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage" -O linuxdeploy.AppImage

echo "Downloading linuxdeploy GTK plugin..."
wget -nv "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh" -O linuxdeploy-plugin-gtk.sh

chmod +x linuxdeploy.AppImage linuxdeploy-plugin-gtk.sh

APPIMAGE_EXTRACT_AND_RUN=1 ./linuxdeploy.AppImage \
  --appdir "$APPDIR" \
  --desktop-file "$APPDIR/usr/share/applications/$APP_NAME.desktop" \
  --icon-file "$ICON_FILE" \
  --plugin gtk \
  --output appimage

generated_appimage=""
for f in ./*.AppImage; do
  if [[ "$f" != "./linuxdeploy.AppImage" ]]; then
    generated_appimage="$f"
    break
  fi
done

if [[ -z "$generated_appimage" ]]; then
  echo "No AppImage generated."
  exit 1
fi

mv "$generated_appimage" "$ROOT_DIR/$OUTPUT_NAME"
popd >/dev/null

sha256sum "$ROOT_DIR/$OUTPUT_NAME" > "$ROOT_DIR/$OUTPUT_NAME.sha256"
echo "Created:"
echo "  $ROOT_DIR/$OUTPUT_NAME"
echo "  $ROOT_DIR/$OUTPUT_NAME.sha256"
