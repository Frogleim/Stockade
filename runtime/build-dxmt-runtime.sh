#!/bin/bash
# Builds the "Wine 11.0 + DXMT 0.80" runtime used by Stockade.
#
#   base:    Gcenx wine-stable 11.0_1 in /Applications/Wine Stable.app (left untouched; cloned)
#   rebuilt: lib/wine/x86_64-unix/winemac.so from wine-11.0 with
#            - -fvisibility=default, so DXMT can find the macOS driver functions
#            - patches/wine-11.0-winemac-dxmt-layout.patch, so DXMT's view of
#              struct macdrv_win_data matches Wine 11's layout
#   added:   DXMT v0.80 "builtin" files (LGPL)
#
# Requires: Xcode, Homebrew bison flex gettext pkg-config mingw-w64, Rosetta 2.
# Usage: runtime/build-dxmt-runtime.sh [work-dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HOME/Developer/wine-build}"
BASE_APP="/Applications/Wine Stable.app"
OUT="$HOME/Library/Application Support/io.github.frogleim.stockade/Runtimes/Wine 11.0 DXMT 0.80.app"
WINE_TAG="wine-11.0"
WINE_COMMIT="db11d0fe6a169c457e23d007e20404643d067aa8"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
DXMT_SHA256="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"

[[ -x "$BASE_APP/Contents/Resources/wine/bin/wine" ]] || { echo "Install Gcenx wine-stable 11.0_1 to $BASE_APP first" >&2; exit 1; }
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH"
mkdir -p "$WORK"

# 1. Wine source at the exact release commit, with the layout patch.
if [[ ! -d "$WORK/wine/.git" ]]; then
    git clone --branch "$WINE_TAG" --depth 1 https://gitlab.winehq.org/wine/wine.git "$WORK/wine"
fi
[[ "$(git -C "$WORK/wine" rev-parse HEAD)" == "$WINE_COMMIT" ]] || { echo "unexpected Wine commit" >&2; exit 1; }
git -C "$WORK/wine" apply --check "$HERE/patches/wine-11.0-winemac-dxmt-layout.patch" 2>/dev/null \
    && git -C "$WORK/wine" apply "$HERE/patches/wine-11.0-winemac-dxmt-layout.patch"

# 2. x86-64 configure and a targeted build of the macOS driver only.
mkdir -p "$WORK/build"
if [[ ! -f "$WORK/build/Makefile" ]]; then
    (cd "$WORK/build" && arch -x86_64 ../wine/configure --enable-win64 --disable-tests \
        --without-x --without-freetype --without-gstreamer --without-sdl --without-cups --without-sane \
        --without-gphoto --without-krb5 --without-netapi --without-pcap --without-usb --without-v4l2 \
        --without-wayland --without-dbus --without-gnutls --without-capi --without-opencl --without-inotify \
        --without-pulse --without-alsa --without-oss --without-udev --without-unwind \
        CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" \
        CFLAGS='-fvisibility=default -O2 -Wno-error' OBJCFLAGS='-fvisibility=default -O2 -Wno-error')
fi
arch -x86_64 make -C "$WORK/build" -j"$(sysctl -n hw.logicalcpu)" dlls/winemac.drv/winemac.so
WINEMAC="$WORK/build/dlls/winemac.drv/winemac.so"
nm -gU "$WINEMAC" | grep -q " T _get_win_data" || { echo "winemac.so does not export get_win_data" >&2; exit 1; }

# 3. DXMT, verified.
mkdir -p "$WORK/dxmt-v0.80/x"
[[ -f "$WORK/dxmt-v0.80/dxmt.tar.gz" ]] || curl -fsSL -o "$WORK/dxmt-v0.80/dxmt.tar.gz" "$DXMT_URL"
echo "$DXMT_SHA256  $WORK/dxmt-v0.80/dxmt.tar.gz" | shasum -a 256 -c
tar -xzf "$WORK/dxmt-v0.80/dxmt.tar.gz" -C "$WORK/dxmt-v0.80/x"
DX="$WORK/dxmt-v0.80/x/v0.80"

# 4. Assemble the runtime from an APFS clone of the base.
mkdir -p "$(dirname "$OUT")"
[[ -e "$OUT" ]] || cp -cR "$BASE_APP" "$OUT"
LIB="$OUT/Contents/Resources/wine/lib/wine"
cp "$WINEMAC" "$LIB/x86_64-unix/winemac.so"
cp "$DX/x86_64-unix/winemetal.so" "$LIB/x86_64-unix/"
for dll in winemetal d3d11 dxgi d3d10core; do
    cp "$DX/x86_64-windows/$dll.dll" "$LIB/x86_64-windows/"
    cp "$DX/i386-windows/$dll.dll" "$LIB/i386-windows/"
done
codesign --force --deep -s - "$OUT"
echo "Runtime ready: $OUT"
echo "Each prefix also needs winemetal.dll in drive_c/windows/system32 (x86_64) and syswow64 (i386)."
