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
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$ROOT_DIR/.appimage-build"
APPDIR="$WORK_DIR/AppDir"
APP_NAME="muon-pdf"
DESKTOP_FILE="$ROOT_DIR/muon-pdf.desktop"
BIN_FILE="$ROOT_DIR/zig-out/bin/$APP_NAME"
SOURCE_ICON_FILE="$ROOT_DIR/icon/256x256.png"
ICON_FILE="$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_NAME.png"
PORTABLE_HOOK_SRC="$SCRIPT_DIR/muon-pdf-portable.sh"

if [[ ! -f "$BIN_FILE" ]]; then
  echo "Missing built binary: $BIN_FILE"
  exit 1
fi

if [[ ! -f "$DESKTOP_FILE" ]]; then
  echo "Missing desktop file: $DESKTOP_FILE"
  exit 1
fi

if [[ ! -f "$SOURCE_ICON_FILE" ]]; then
  echo "Missing icon file: $SOURCE_ICON_FILE"
  exit 1
fi

if [[ ! -f "$PORTABLE_HOOK_SRC" ]]; then
  echo "Missing portable hook: $PORTABLE_HOOK_SRC"
  exit 1
fi

case "$ARCH" in
  x86_64)  HOST_LIBDIR=/usr/lib/x86_64-linux-gnu ;;
  aarch64) HOST_LIBDIR=/usr/lib/aarch64-linux-gnu ;;
esac

bundle_extra_libraries() {
  local lib
  local -a libs=(
    libwayland-client.so.0
    libwayland-cursor.so.0
    libwayland-egl.so.1
    libxkbcommon.so.0
    libharfbuzz.so.0
    libfontconfig.so.1
    libfribidi.so.0
    libX11.so.6
    libxcb.so.1
    libX11-xcb.so.1
  )

  echo "Bundling extra display/input libraries for fallback systems..."
  for lib in "${libs[@]}"; do
    if [[ -f "$HOST_LIBDIR/$lib" ]]; then
      APPIMAGE_EXTRACT_AND_RUN=1 ./linuxdeploy.AppImage \
        --appdir "$APPDIR" \
        --library "$HOST_LIBDIR/$lib" || true
    fi
  done
}

apply_portability_fixes() {
  echo "Applying cross-distro portability fixes..."

  find "$APPDIR/usr/lib/gtk-4.0" -name 'libim-ibus.so' -delete 2>/dev/null || true

  mkdir -p "$APPDIR/apprun-hooks"
  cp "$PORTABLE_HOOK_SRC" "$APPDIR/apprun-hooks/muon-pdf-portable.sh"
  chmod +x "$APPDIR/apprun-hooks/muon-pdf-portable.sh"

  cat >"$APPDIR/AppRun" <<'EOF'
#! /usr/bin/env bash
set -e
this_dir="$(readlink -f "$(dirname "$0")")"
source "$this_dir"/apprun-hooks/linuxdeploy-plugin-gtk.sh
source "$this_dir"/apprun-hooks/muon-pdf-portable.sh
exec "$this_dir"/AppRun.wrapped "$@"
EOF
  chmod +x "$APPDIR/AppRun"
}

rm -rf "$WORK_DIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$(dirname -- "$ICON_FILE")"

cp "$BIN_FILE" "$APPDIR/usr/bin/$APP_NAME"
cp "$DESKTOP_FILE" "$APPDIR/usr/share/applications/$APP_NAME.desktop"
cp "$SOURCE_ICON_FILE" "$ICON_FILE"

if ! grep -q '^Icon=' "$APPDIR/usr/share/applications/$APP_NAME.desktop"; then
  printf '\nIcon=%s\n' "$APP_NAME" >> "$APPDIR/usr/share/applications/$APP_NAME.desktop"
fi

icon_mime_type="$(file -b --mime-type "$ICON_FILE")"
if [[ "$icon_mime_type" != "image/png" ]]; then
  echo "Icon file is not a valid PNG: $ICON_FILE ($icon_mime_type)"
  exit 1
fi

pushd "$WORK_DIR" >/dev/null

echo "Downloading linuxdeploy ($ARCH)..."
wget -nv "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage" -O linuxdeploy.AppImage

echo "Downloading linuxdeploy GTK plugin..."
wget -nv "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh" -O linuxdeploy-plugin-gtk.sh

chmod +x linuxdeploy.AppImage linuxdeploy-plugin-gtk.sh

echo "Deploying AppDir with GTK plugin..."
APPIMAGE_EXTRACT_AND_RUN=1 ./linuxdeploy.AppImage \
  --appdir "$APPDIR" \
  --desktop-file "$APPDIR/usr/share/applications/$APP_NAME.desktop" \
  --icon-file "$ICON_FILE" \
  --plugin gtk

bundle_extra_libraries
apply_portability_fixes

echo "Generating AppImage..."
APPIMAGE_EXTRACT_AND_RUN=1 ./linuxdeploy.AppImage \
  --appdir "$APPDIR" \
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
