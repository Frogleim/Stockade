# Compatibility baseline (Phase 0 / FL-001)

**Status: game reaches gameplay (2026-10-26).** The main menu and a new game work on the
runtime below. The exit gate still needs a save → quit → relaunch → reload cycle and a
30-minute session. The launcher stays labeled experimental until it passes.

## Host

| Field | Value |
| --- | --- |
| Date | 2026-10-26 |
| Mac model / chip | Mac15,6 — Apple M3 Pro |
| Memory | 18 GB |
| macOS build | 26.5.1 (25F80) |
| Xcode | 26.6 (17F113) |
| Free disk space | ~100 GB after game (12.5 GB) and runtimes |
| Rosetta 2 installed | Yes |
| Audio devices | Built-in speakers/mic, P27q-20 (HDMI), iPhone Continuity mic, Microsoft Teams Audio (virtual), ParrotAudioPlugin HAL driver |

## Working runtime: Wine 11.0 + DXMT 0.80

Built by `runtime/build-dxmt-runtime.sh`; the runtime folder carries `Contents/Resources/STOCKADE-RUNTIME.txt`.

| Field | Value |
| --- | --- |
| Base | Gcenx wine-stable 11.0_1 — https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1 (archive sha256 `b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388`) |
| Version (`wine --version`) | wine-11.0 |
| SHA-256 of `wine` | `bad3b6126b6612680e26302c0e0b7e56d6c7036eac9bf6313878bdd9039b003f` |
| Architecture | x86_64 (Rosetta 2) |
| Rebuilt | `x86_64-unix/winemac.so` from wine-11.0 (`db11d0f`), `-fvisibility=default`, plus `runtime/patches/wine-11.0-winemac-dxmt-layout.patch`; built without MoltenVK |
| Graphics | DXMT v0.80 builtin (sha256 `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`, LGPL) — Unity reports Direct3D 11.0, feature level 11.1, "Apple M3 Pro" |
| Media | GStreamer 1.28.8 runtime (universal) in /Library/Frameworks — required for in-game video |
| Location | `~/Library/Application Support/io.github.frogleim.stockade/Runtimes/Wine 11.0 DXMT 0.80.app` (the `/Applications` original is untouched) |

### Why the patch exists

DXMT finds the window to draw into by reading Wine's private `struct macdrv_win_data` as
`{hwnd, cocoa_window, cocoa_view, client_cocoa_view}`. Wine 11 changed it in two ways:

1. `cocoa_view` was removed, so the 4th pointer slot became the start of `rects`.
2. `client_view` is only set for windows with a GL/Vulkan client surface, so it is NULL for D3D windows.

DXMT then created no Metal view (log: `Failed to create metal view, it seems like your Wine has
no exported symbols needed by DXMT`) and Unity aborted with exit code 3 right after
`<RI> Input initialized.` The patch adds `dxmt_view` at offset 24, kept equal to the client view
or, failing that, the window's content view (`macdrv_get_window_content_view`). Verified with an
`offsetof` check.

## Prefix

`~/Library/Application Support/io.github.frogleim.stockade/Prefixes/Farthest Frontier Prefix`
(path with spaces). Created with Wine Stable 11.0_1 and adopted by the DXMT build of the same
Wine version (`stockade-cli adopt-prefix`).

| Prefix setting | Why |
| --- | --- |
| `winemetal.dll` in `system32` and `syswow64` | Required by DXMT builtin install |
| `HKCU\Software\Wine\AppDefaults\{steam,steamwebhelper,steamwebhelper_real,steamservice}.exe\DllOverrides` `winecoreaudio.drv=""` | Steam's web view aborted in `mmdevapi` (`Assertion failed: !status … mmdevapi_private.h:120`); the game keeps audio |
| Steam client options `-cef-disable-gpu -no-cef-sandbox -noverifyfiles` | `-noverifyfiles` keeps the web helper shim in place |
| steamwebhelper shim (`Tools/steamwebhelper-shim`) | Adds `--disable-gpu --single-process`; without it Steam's window is black (CEF 126 on Wine 11) |

Equivalent manual launch (what `stockade-cli plan` prints, user name redacted):

```
WINEPREFIX=~/Library/Application Support/io.github.frogleim.stockade/Prefixes/Farthest Frontier Prefix
WINEDEBUG=-all
PATH=<runtime>/Contents/Resources/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin
<runtime>/Contents/Resources/wine/bin/wine "<prefix>/drive_c/Program Files (x86)/Steam/steam.exe" \
  -cef-disable-gpu -no-cef-sandbox -noverifyfiles -applaunch 1044720
```

## Game

| Field | Value |
| --- | --- |
| Game build | 23662091 (Unity 2022.3.62f3, IL2CPP) |
| Game executable / process name | `Farthest Frontier.exe` (matches the default detection hint) |
| Save directories | `drive_c/users/<user>/AppData/Local/Farthest Frontier/Save` and `…/Saved Games/Farthest Frontier/Save` (Steam Cloud created both; verify which one the game writes) |
| Steam Cloud enabled | Yes |
| Logging | `boot.config` has `nolog=`; pass `-logFile C:\users\Public\player.log` via `stockade-cli game-args` to diagnose |

## Results

| Check | Result | Notes |
| --- | --- | --- |
| Steam installs and signs in | ✅ with workarounds | First post-update relaunch exited silently; the second start worked |
| Game installs through Steam | ✅ | 12.5 GB |
| Main menu reached | ✅ | DXMT, D3D11 FL 11.1 |
| New settlement created | ✅ | Needed GStreamer for the intro video (`WindowsVideoMedia error 0xc00d36bb`) |
| Save, quit, relaunch, reload | ☐ | |
| 30+ minutes of play | ☐ | First session ~3 min, quit normally (exit 0) |
| Rendering artifacts | ☐ | |
| Input (mouse, keyboard, scrolling) | ☐ | |
| Audio | ☐ | CoreAudio initialized in the game process |
| Crashes / hangs | ☐ | |

## Runtimes that did not work

| Runtime | Result |
| --- | --- |
| Wine Stable 11.0_1, WineD3D (OpenGL) | Unity: "Failed to initialize player / graphics" — macOS OpenGL 4.1 cannot provide D3D11 FL 10+ |
| Wine Stable 11.0_1, WineD3D Vulkan renderer (MoltenVK) | Same; MoltenVK has no geometry shaders |
| Game Porting Toolkit 3.0-3 (Gcenx), Wine 7.7 + D3DMetal | Steam 2026 client crashes after updating (`Unhandled page fault on read access to 0000000000000081`) |

## Exit gate

- [ ] A clean prefix reproduces a playable session and a save reload.
