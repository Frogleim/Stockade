#!/bin/bash
# Builds the steamwebhelper shim (a Windows executable) with mingw-w64.
# Output: Tools/steamwebhelper-shim/build/steamwebhelper-shim.exe
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CC:-x86_64-w64-mingw32-gcc}"
OUT="$ROOT/Tools/steamwebhelper-shim/build"

command -v "$CC" >/dev/null || { echo "$CC not found. Install it with: brew install mingw-w64" >&2; exit 1; }
mkdir -p "$OUT"
"$CC" -municode -mwindows -O2 -Wall -Wextra -static -s \
    -o "$OUT/steamwebhelper-shim.exe" "$ROOT/Tools/steamwebhelper-shim/shim.c"
grep -q FRONTIER_LAUNCHER_WEBHELPER_SHIM_V1 "$OUT/steamwebhelper-shim.exe" || { echo "marker missing from build" >&2; exit 1; }
echo "Built $OUT/steamwebhelper-shim.exe ($(stat -f%z "$OUT/steamwebhelper-shim.exe") bytes)"
