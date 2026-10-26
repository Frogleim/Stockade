#!/bin/bash
# Builds a Release Stockade.app (ad-hoc signed) and a zip into dist/.
# Usage: scripts/build-app.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
BUNDLE_ID="io.github.frogleim.stockade"
DIST="$ROOT/dist"
APP="$DIST/Stockade.app"

cd "$ROOT"
swift build -c release --product Stockade
swift build -c release --product stockade-cli
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Stockade" "$APP/Contents/MacOS/Stockade"
cp "$BIN_DIR/stockade-cli" "$APP/Contents/Resources/stockade-cli"

# App icon: every size macOS uses, generated from the 1024 px master.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/assets/icon/stockade-icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT/assets/icon/stockade-icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Stockade</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Stockade</string>
    <key>CFBundleDisplayName</key><string>Stockade</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature for local use. Distribution needs Developer ID signing,
# the hardened runtime and notarization (see docs/architecture.md).
codesign --force --sign - "$APP/Contents/Resources/stockade-cli"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

(cd "$DIST" && rm -f "Stockade-${VERSION}.zip" && ditto -c -k --keepParent "Stockade.app" "Stockade-${VERSION}.zip")
echo "Built: $APP"
echo "Zip:   $DIST/Stockade-${VERSION}.zip"
