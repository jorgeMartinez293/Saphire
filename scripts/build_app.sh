#!/bin/bash
# Build Saphire.app from the SPM executable + resources.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="Saphire.app"
BUILD_DIR=".build/$CONFIG"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Saphire" "$APP/Contents/MacOS/Saphire"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "Resources/web" "$APP/Contents/Resources/web"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "   (codesign skipped)"

echo "==> done: $(pwd)/$APP"
