#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ICON_SOURCE="$PWD/Sources/PingTask/Resources/png_enemymissing_128x128.png"
ICON_SET="$PWD/.build/PingTask.iconset"
mkdir -p "$ICON_SET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICON_SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICON_SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICON_SET" --output "$PWD/.build/PingTask.icns"
