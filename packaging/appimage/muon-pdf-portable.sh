#!/usr/bin/env bash
# Sourced from AppRun after linuxdeploy-plugin-gtk.sh.

# The upstream GTK plugin forces X11 only, which breaks Wayland-only desktops.
export GDK_BACKEND="wayland,x11"

# Avoid loading the bundled IBus input module (libibus is not on $ORIGIN for immodules).
export GTK_IM_MODULE="${GTK_IM_MODULE:-simple}"

# Prefer the host GTK stack when available. Distro GTK integrates correctly with the
# local compositor (Wayland/X11); the Ubuntu-bundled copy is only a fallback.
case "$(uname -m)" in
    x86_64)  _multiarch=lib/x86_64-linux-gnu ;;
    aarch64) _multiarch=lib/aarch64-linux-gnu ;;
    *)       _multiarch=lib ;;
esac

for _libdir in "/usr/${_multiarch}" /usr/lib /usr/lib64; do
    if [ -f "${_libdir}/libgtk-4.so.1" ]; then
        export LD_LIBRARY_PATH="${_libdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
        # Stop linuxdeploy from redirecting GTK to the bundled Ubuntu tree.
        unset GTK_EXE_PREFIX
        unset GTK_PATH
        unset GTK_DATA_PREFIX
        unset GSETTINGS_SCHEMA_DIR
        unset GI_TYPELIB_PATH
        unset GDK_PIXBUF_MODULE_FILE
        break
    fi
done

# A stale DISPLAY=:0 on Wayland-only sessions (no XWayland socket) makes GDK fail.
if [ -n "${DISPLAY:-}" ]; then
    _display_num="${DISPLAY#*:}"
    _display_num="${_display_num%%.*}"
    if [ -n "$_display_num" ] && [ ! -S "/tmp/.X11-unix/X${_display_num}" ]; then
        unset DISPLAY
    fi
fi
