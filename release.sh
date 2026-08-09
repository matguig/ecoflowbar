#!/bin/bash
# Construit un EcoFlowBar.app AUTONOME (démon embarqué + wheels hors-ligne),
# le signe, l'empaquette en DMG et le notarise.
#
# Usage :  ./release.sh <version>            ex: ./release.sh 1.0.0
#
# Variables d'environnement (sinon build ad-hoc non distribuable) :
#   EF_SIGN_IDENTITY   ex: "Developer ID Application: Matthieu Guigon (TEAMID)"
#   EF_NOTARY_PROFILE  profil notarytool (xcrun notarytool store-credentials)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:?usage: ./release.sh <version>}"
BUILD="$DIR/build"
APP="$BUILD/EcoFlowBar.app"
DMG="$BUILD/EcoFlowBar-$VERSION.dmg"

echo "==> Nettoyage"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/daemon"

echo "==> Compilation Swift (universel non requis : Apple Silicon)"
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
    <string>Recherche et appairage de la batterie EcoFlow en Bluetooth.</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> Ressources : icône + démon embarqué"
cp "$DIR/assets/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$DIR/scripts" "$APP/Contents/Resources/daemon/scripts"
rm -rf "$APP/Contents/Resources/daemon/scripts/__pycache__"
cp -R "$DIR/vendor" "$APP/Contents/Resources/daemon/vendor"
find "$APP/Contents/Resources/daemon/vendor" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
cp "$DIR/assets/daemon-run.sh" "$APP/Contents/Resources/daemon/run.sh"
chmod +x "$APP/Contents/Resources/daemon/run.sh" \
    "$APP/Contents/Resources/daemon/scripts/"*.sh

echo "==> Python autonome embarqué (aucun prérequis chez l'utilisateur)"
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
# Allègement : caches et tests inutiles à l'exécution
find "$APP/Contents/Resources/daemon/python" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
rm -rf "$APP/Contents/Resources/daemon/python/lib/python3.13/test"

echo "==> Signature"
if [ -n "${EF_SIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$DIR/assets/entitlements.plist" \
        --sign "$EF_SIGN_IDENTITY" "$APP"
    echo "    signé : $EF_SIGN_IDENTITY (hardened runtime)"
else
    codesign --force --deep --sign - "$APP"
    echo "    ⚠ signature ad-hoc : build de test, NON distribuable"
fi

echo "==> DMG"
DMG_SRC="$BUILD/dmg"
mkdir -p "$DMG_SRC"
cp -R "$APP" "$DMG_SRC/"
ln -s /Applications "$DMG_SRC/Applications"
hdiutil create -volname "EcoFlowBar" -srcfolder "$DMG_SRC" -ov -quiet \
    -format UDZO "$DMG"

if [ -n "${EF_NOTARY_PROFILE:-}" ]; then
    echo "==> Notarisation (peut prendre quelques minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$EF_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "    DMG notarisé et staplé"
else
    echo "    ⚠ notarisation sautée (EF_NOTARY_PROFILE absent)"
fi

echo
echo "Prêt : $DMG"
du -h "$DMG" | cut -f1
