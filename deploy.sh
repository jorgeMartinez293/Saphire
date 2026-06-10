#!/usr/bin/env bash
# Build, deploy into Saphire.app, resign, and relaunch.
# The binary lives in Saphire.app/Contents/MacOS/Saphire — `swift build`
# alone only updates .build/, so it must be copied into the bundle every time.
set -euo pipefail

cd "$(dirname "$0")"

APP="Saphire.app"
BIN="$APP/Contents/MacOS/Saphire"

echo "==> Building release..."
swift build -c release

echo "==> Assembling bundle (if needed)..."
if [ ! -d "$APP/Contents/MacOS" ]; then
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "Resources/Info.plist" "$APP/Contents/Info.plist"
    cp -R "Resources/web" "$APP/Contents/Resources/web"
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    cp "Resources/saphire-logo.png" "$APP/Contents/Resources/saphire-logo.png"
    cp "Resources/search.png" "$APP/Contents/Resources/search.png"
fi

cp "Resources/saphire-logo.png" "$APP/Contents/Resources/saphire-logo.png"
cp "Resources/search.png" "$APP/Contents/Resources/search.png"
# Always refresh web assets (chat.html etc.) so frontend edits land even when
# the bundle already exists — the assembly step above only runs on first build.
cp -R "Resources/web/." "$APP/Contents/Resources/web/"
# Always refresh Info.plist so plist changes (e.g. usage-description keys for
# TCC permissions) land even when the bundle already exists.
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> Deploying binary into $APP..."
cp .build/release/Saphire "$BIN"

echo "==> Re-signing bundle..."
# Sign with a STABLE code-signing identity (not ad-hoc). TCC permissions
# (Full Disk Access for WhatsApp, Automation/Apple Events for Mail) are keyed
# to the code signature's *designated requirement*. Ad-hoc signing (`--sign -`)
# bakes the per-build cdhash into that requirement, so every redeploy minted a
# new identity and silently invalidated previously granted permissions — the
# tools then "returned nothing" with no re-prompt. A real cert anchors the
# requirement to (bundle id + certificate), which stays constant across builds,
# so grants survive redeploys.
#
# Set SIGN_ID to your own signing identity — the SHA-1 hash or the full name of
# a certificate from `security find-identity -v -p codesigning`
# (e.g. "Apple Development: you@example.com (XXXXXXXXXX)"). A free Apple
# Development certificate from Xcode works. Leave empty to fall back to ad-hoc
# signing (TCC permissions for WhatsApp/Mail reset on every redeploy).
SIGN_ID="${SIGN_ID:-}"
if [ -n "$SIGN_ID" ] && security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "    WARNING: stable signing identity not found; falling back to ad-hoc."
    echo "    Permissions (WhatsApp/Mail) will reset on every redeploy."
    codesign --force --sign - "$APP"
fi

echo "==> Relaunching..."
# Kill any running instance from this bundle, then open fresh.
pkill -f "$PWD/$BIN" 2>/dev/null || true
sleep 0.3
open "$APP"

# Keep the /Applications copy in sync. Saphire is sometimes launched from
# /Applications (Spotlight/login item); if that copy lags behind, old bugs
# "reappear" even though the project bundle was fixed. Any instance running
# from there is stopped too — two concurrent instances fight over the hotkey
# and the database.
if [ -d "/Applications/Saphire.app" ]; then
    echo "==> Syncing /Applications/Saphire.app..."
    pkill -f "/Applications/Saphire.app/Contents/MacOS/Saphire" 2>/dev/null || true
    ditto "$APP" "/Applications/Saphire.app"
fi

echo "==> Done. New build running."
