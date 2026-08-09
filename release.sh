#!/bin/bash
# Builds a SELF-CONTAINED EcoFlowBar.app (embedded daemon + offline wheels),
# signs it, packages it into a DMG and notarizes it.
#
# Usage:  ./release.sh <version>            e.g. ./release.sh 1.0.0
#
# Environment variables (otherwise an ad-hoc, non-distributable build):
#   EF_SIGN_IDENTITY   e.g. "Developer ID Application: Matthieu Guigon (TEAMID)"
#   EF_NOTARY_PROFILE  notarytool profile (xcrun notarytool store-credentials)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:?usage: ./release.sh <version>}"
BUILD="$DIR/build"
APP="$BUILD/EcoFlowBar.app"
DMG="$BUILD/EcoFlowBar-$VERSION.dmg"

echo "==> Cleanup"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/daemon"

echo "==> Swift compilation (universal not required: Apple Silicon)"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    "$DIR"/app/*.swift -o "$APP/Contents/MacOS/EcoFlowBar"

echo "==> Info.plist ($VERSION)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>fr.koa.ecoflow-bar</string>
    <key>CFBundleName</key>
    <string>EcoFlowBar</string>
    <key>CFBundleExecutable</key>
    <string>EcoFlowBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Discovers and pairs your EcoFlow battery over Bluetooth.</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> Resources: icon + embedded daemon"
cp "$DIR/assets/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$DIR/scripts" "$APP/Contents/Resources/daemon/scripts"
rm -rf "$APP/Contents/Resources/daemon/scripts/__pycache__"
cp -R "$DIR/vendor" "$APP/Contents/Resources/daemon/vendor"
find "$APP/Contents/Resources/daemon/vendor" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
cp "$DIR/assets/daemon-run.sh" "$APP/Contents/Resources/daemon/run.sh"
chmod +x "$APP/Contents/Resources/daemon/run.sh" \
    "$APP/Contents/Resources/daemon/scripts/"*.sh

echo "==> Embedded standalone Python (no prerequisites on the user's machine)"
PYVER="3.13.1"
PYTAG="20250115"
PYURL="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTAG/cpython-$PYVER+$PYTAG-aarch64-apple-darwin-install_only.tar.gz"
PYCACHE="$DIR/.cache/cpython-$PYVER-$PYTAG.tar.gz"
mkdir -p "$DIR/.cache"
if [ ! -f "$PYCACHE" ]; then
    curl -fsSL -o "$PYCACHE" "$PYURL"
fi
tar -xzf "$PYCACHE" -C "$APP/Contents/Resources/daemon/"
"$APP/Contents/Resources/daemon/python/bin/python3" -m pip install --quiet \
    bleak bleak-retry-connector ecdsa pycryptodome protobuf aiohttp
# Slimming down: caches and tests not needed at runtime
find "$APP/Contents/Resources/daemon/python" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
rm -rf "$APP/Contents/Resources/daemon/python/lib/python3.13/test"

echo "==> Signing"
if [ -n "${EF_SIGN_IDENTITY:-}" ]; then
    ENT="$DIR/assets/entitlements.plist"
    # "Inside-out" signing: each embedded Mach-O binary (python,
    # .dylib, .so of the standalone Python) is signed individually with the
    # hardened runtime + timestamp, otherwise notarization returns "Invalid".
    # --deep does not do this correctly for an embedded interpreter.
    # We test each file with `file` (portable BSD/GNU, no -perm).
    echo "    signing embedded binaries…"
    COUNT=0
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q "Mach-O"; then
            codesign --force --options runtime --timestamp \
                --entitlements "$ENT" --sign "$EF_SIGN_IDENTITY" "$f"
            COUNT=$((COUNT + 1))
        fi
    done < <(find "$APP/Contents/Resources/daemon" -type f -print0)
    echo "    $COUNT binaries signed"
    # Then the bundle itself (covers the main Swift executable)
    codesign --force --options runtime --timestamp \
        --entitlements "$ENT" --sign "$EF_SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP" && echo "    verified OK"
    echo "    signed: $EF_SIGN_IDENTITY (hardened runtime, inside-out)"
else
    codesign --force --deep --sign - "$APP"
    echo "    ⚠ ad-hoc signature: test build, NOT distributable"
fi

echo "==> DMG"
DMG_SRC="$BUILD/dmg"
mkdir -p "$DMG_SRC"
cp -R "$APP" "$DMG_SRC/"
ln -s /Applications "$DMG_SRC/Applications"
hdiutil create -volname "EcoFlowBar" -srcfolder "$DMG_SRC" -ov -quiet \
    -format UDZO "$DMG"

if [ -n "${EF_NOTARY_PROFILE:-}" ]; then
    echo "==> Notarization (may take a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$EF_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "    DMG notarized and stapled"
else
    echo "    ⚠ notarization skipped (EF_NOTARY_PROFILE not set)"
fi

echo
echo "Ready: $DMG"
du -h "$DMG" | cut -f1
