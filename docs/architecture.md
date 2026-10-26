# Architecture and decisions

## Components

```
SwiftUI app (Stockade)      stockade-cli (development harness)
            \                         /
             LauncherEngine (actor) — single shared API
               ├─ ConfigurationStore     atomic JSON, schema check, last-good recovery
               ├─ RuntimeDiscovery       validate wine/wineserver, version, Mach-O arch, SHA-256, backend files
               ├─ RuntimeAdapter         LaunchAction → LaunchPlan (StandardWineAdapter)
               ├─ ProcessSupervisor      Process + concurrent pipe draining, timeouts, owned-only termination
               ├─ PrefixManager          create / initialize (marker) / delete (owned, inactive, confirmed)
               ├─ PrefixLock             flock per prefix, across processes
               ├─ PrefixObserver         same-user processes whose WINEPREFIX is ours (KERN_PROCARGS2)
               ├─ SessionStateMachine    pure, truthful lifecycle transitions
               ├─ SteamService           locate steam.exe, VDF library + appmanifest reading
               ├─ LogStore / Redactor    rotation, size bounds, redaction
               ├─ DiagnosticsReportBuilder
               └─ BackupService          checksummed manifests, staged verified restore
```

## Decisions

| # | Decision | Reason |
| --- | --- | --- |
| ADR-1 | SwiftPM packages instead of an `.xcodeproj` | Reproducible from the command line; Xcode opens `Package.swift`. `scripts/build-app.sh` assembles the `.app`. |
| ADR-2 | `LauncherCore` has no UI imports | Testable headlessly; `stockade-cli` and the app share one API. |
| ADR-3 | `Process` with argument arrays, never `sh -c` | No shell injection through paths or profile fields (tested). |
| ADR-4 | Environment allowlist (`EnvironmentPolicy`) | Host `WINEDLLOVERRIDES`, `DYLD_*`, shell `PATH` and secrets never leak into Wine. |
| ADR-5 | x86-64 runtimes are executed directly | macOS applies Rosetta automatically; no universal `arch -x86_64` wrapper. |
| ADR-6 | Only `runtimeDefault` backend offered | Backend switching waits until two combinations are verified. Detection of DXMT/D3DMetal files is informational. |
| ADR-7 | Steam and installers run detached, output to a log file | No pipe ties them to the launcher, so quitting the launcher cannot kill them with SIGPIPE. Short tools (wineboot, wineserver) use pipes and live output. |
| ADR-8 | Prefix activity from the wineserver lock; game observation from `tasklist.exe` | `/tmp/.wine-<uid>/server-<dev>-<inode>/lock` is held while anything runs in that prefix, so checking it has no side effects. `tasklist` asks that prefix's wineserver for Windows image names and only runs while the server is up. Matching `WINEPREFIX` in process environments proved unreliable because Wine overwrites its processes' argument area. |
| ADR-13 | One prefix per runtime; `adopt-prefix` only for the same Wine version | Different Wine versions never share a prefix. A rebuilt driver of the same release may take over an existing prefix. |
| ADR-14 | Runtime = APFS clone of Gcenx Wine 11.0 + rebuilt `winemac.so` + DXMT 0.80 | Plain WineD3D cannot provide D3D11 FL 10+ on macOS; GPTK's Wine 7.7 cannot run 2026 Steam. See `runtime/` and the compatibility baseline. |
| ADR-15 | steamwebhelper shim, re-applied before every Steam start | Steam's CEF 126 paints black under Wine 11 unless `--single-process`, which Steam's own options cannot set. Valve's binary is kept and restored by `webhelper-shim --remove`. |
| ADR-9 | Lock files outside the prefix | Deleting a prefix can hold its lock throughout. |
| ADR-10 | Prefix marker written only after `wineboot --init` and `wineserver -w` succeed | Interrupted initialization is distinguishable from a valid prefix. |
| ADR-11 | Restore = verify backup → stage → verify staged copy → move current aside → swap | A failure at any step leaves current saves in place. |
| ADR-12 | Configuration from a newer schema is never overwritten | Downgrades can't destroy data; the app runs read-only. |

## Lifecycle

`notConfigured → ready → launchRequested → starting → runningObserved → exited`

- `steam.exe -applaunch` exiting 0 while Steam is already running is a hand-off, not a game exit.
- A non-zero exit before anything is observed is `failed`.
- Nothing observed within 10 minutes → `statusUnknown` (polling continues; a later match still moves to `runningObserved`).
- Configuration from a previous launcher run never claims a session is still running; active phases are reloaded as `statusUnknown`.

## Distribution notes (Phase 6)

The build script signs ad-hoc for local use. A distributed beta needs a Developer ID
certificate, the hardened runtime and notarization. App Sandbox is not used: the launcher
must execute a user-selected external runtime. The runtime, Windows Steam and the game are
never bundled.
