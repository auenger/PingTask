#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PWD/dist/PingTask.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp -R "$BIN_DIR/PingTask_PingTask.bundle" "$APP_DIR/Contents/Resources/"
bash scripts/make-icon.sh
cp "$PWD/.build/PingTask.icns" "$APP_DIR/Contents/Resources/PingTask.icns"
cp "$BIN_DIR/PingTask" "$APP_DIR/Contents/MacOS/PingTask"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PingTask</string>
<key>CFBundleIdentifier</key><string>local.pingtask.prototype</string>
<key>CFBundleName</key><string>PingTask</string>
<key>CFBundleDisplayName</key><string>PingTask</string>
<key>CFBundleIconFile</key><string>PingTask</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
