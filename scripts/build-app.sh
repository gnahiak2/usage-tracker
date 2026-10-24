#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        *) CONFIG="$arg" ;;
    esac
done

if [ "$UNIVERSAL" = 1 ]; then
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c "$CONFIG"
    BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi
APP="dist/UsageTracker.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "dist/icon"
cp "$BIN_DIR/UsageTracker" "$APP/Contents/MacOS/UsageTracker"

# SwiftPM's resource bundle carries Resources/cli.sb, which the sandbox needs at runtime.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# App icon, generated once and cached in dist/.
if [ ! -f "dist/AppIcon.icns" ]; then
    swift scripts/make-icon.swift "dist/icon/icon_1024.png"
    ICONSET="dist/icon/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
                "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
                "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
        set -- $spec
        sips -z "$1" "$1" "dist/icon/icon_1024.png" --out "$ICONSET/$2.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "dist/AppIcon.icns"
fi
cp "dist/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Usage Tracker</string>
    <key>CFBundleDisplayName</key><string>Usage Tracker</string>
    <key>CFBundleIdentifier</key><string>io.github.kaihang.usagetracker</string>
    <key>CFBundleExecutable</key><string>UsageTracker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
lipo -info "$APP/Contents/MacOS/UsageTracker"
