# Wine patches

## wine-11.0-winemac-dxmt-layout.patch

Applies to Wine 11.0 (`db11d0fe6a169c457e23d007e20404643d067aa8`), `dlls/winemac.drv`.

DXMT finds the Cocoa view for a window by reading Wine's private `struct macdrv_win_data`
as `{hwnd, cocoa_window, cocoa_view, client_cocoa_view}`. In Wine 11 the struct begins
`{hwnd, cocoa_window, client_view, rects, …}` and `client_view` is only set for windows
with an OpenGL/Vulkan client surface. DXMT therefore received no view for Direct3D windows
and failed with "Failed to create metal view".

The patch adds `dxmt_view` as the fourth pointer (offset 24), kept equal to the client
view or otherwise the window's content view, and a `macdrv_get_window_content_view()`
helper. It changes nothing for code that uses the struct by field name.

## License

These patches are derived from Wine and are distributed under the GNU Lesser General
Public License, version 2.1 or (at your option) any later version. Wine's full license is
at https://gitlab.winehq.org/wine/wine/-/blob/master/LICENSE and its copyright holders are
listed in Wine's AUTHORS file.
