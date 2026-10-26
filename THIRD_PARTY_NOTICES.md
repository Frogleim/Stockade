# Third-party software

Stockade's own code is MIT-licensed (see `LICENSE`). It does **not** include or
redistribute any of the software below. Each is installed or downloaded separately, and
verified by checksum where Stockade's scripts fetch it.

| Component | Used for | License | Source |
| --- | --- | --- | --- |
| Wine (Gcenx macOS build, 11.0_1) | Windows API compatibility | LGPL-2.1-or-later | https://github.com/Gcenx/macOS_Wine_builds, https://gitlab.winehq.org/wine/wine |
| DXMT v0.80 | Direct3D 10/11 → Metal | LGPL (from v0.80; earlier versions MIT) | https://github.com/3Shain/dxmt |
| GStreamer runtime | Video and audio decoding inside Wine | LGPL-2.1-or-later | https://gstreamer.freedesktop.org |
| mingw-w64 | Builds the steamwebhelper shim | GPL/LGPL toolchain (output not affected) | https://www.mingw-w64.org |

`runtime/patches/` contains changes to Wine and is licensed under the LGPL like Wine.
If you distribute a runtime built with `runtime/build-dxmt-runtime.sh`, you must meet the
LGPL terms of Wine, DXMT and GStreamer, including providing the corresponding source
(Wine 11.0 plus the patch in this repository).

## Credits

- The steamwebhelper shim approach (`--disable-gpu --single-process` for Steam's CEF under
  Wine 11) follows [notpop/steam-on-m1-wine](https://github.com/notpop/steam-on-m1-wine)
  (MIT). Stockade's shim is a separate implementation.
- Gcenx for maintained macOS Wine builds, and the DXMT authors for the Metal translation layer.

## Trademarks

Farthest Frontier is a trademark of Crate Entertainment. Steam is a trademark of Valve
Corporation. Apple, macOS and Metal are trademarks of Apple Inc. Stockade is an unofficial
project and is not affiliated with or endorsed by any of them.
