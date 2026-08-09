#!/bin/bash
# Installation de l'indicateur batterie EcoFlow pour le Mac mini.
# Idempotent : relançable sans risque après un git pull ou un changement de config.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Environnement Python"
if [ ! -x "$DIR/.venv/bin/python" ]; then
    python3 -m venv "$DIR/.venv"
fi
"$DIR/.venv/bin/pip" install -q bleak bleak-retry-connector ecdsa pycryptodome protobuf aiohttp

echo "==> EcoFlowBar (app barre de menus, style Stats)"
BAR_APP="$DIR/EcoFlowBar.app"
mkdir -p "$BAR_APP/Contents/MacOS"
cat > "$BAR_APP/Contents/Info.plist" <<PLIST
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
mkdir -p "$BAR_APP/Contents/Resources"
cp "$DIR/assets/AppIcon.icns" "$BAR_APP/Contents/Resources/"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    "$DIR"/app/*.swift -o "$BAR_APP/Contents/MacOS/EcoFlowBar"
codesign --force --sign - "$BAR_APP" 2>/dev/null || true

sed "s|__PROJECT_DIR__|$DIR|g" "$DIR/launchd/fr.koa.ecoflow-bar.plist.in" \
    > "$HOME/Library/LaunchAgents/fr.koa.ecoflow-bar.plist"
launchctl bootout "gui/$(id -u)/fr.koa.ecoflow-bar" 2>/dev/null || true
pkill -f EcoFlowBar.app 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/fr.koa.ecoflow-bar.plist"

echo "==> Nettoyage des anciens agents (démon désormais géré par l'app)"
launchctl bootout "gui/$(id -u)/fr.koa.ecoflow-monitor" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/fr.koa.ecoflow-monitor.plist"
rm -rf "$DIR/EcoFlowMonitor.app"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod +x "$DIR/scripts/ef_hibernate.sh" "$DIR/scripts/ef_restore.sh"

echo "==> LaunchAgent (restauration de session post-hibernation)"
sed "s|__PROJECT_DIR__|$DIR|g" "$DIR/launchd/fr.koa.ecoflow-restore.plist.in" \
    > "$HOME/Library/LaunchAgents/fr.koa.ecoflow-restore.plist"
launchctl bootout "gui/$(id -u)/fr.koa.ecoflow-restore" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/fr.koa.ecoflow-restore.plist"


cat <<'EOF'

Installation terminée.

L'app EcoFlowBar est lancée : l'assistant de configuration s'ouvre au premier
démarrage (compte EcoFlow, appairage Bluetooth, autorisations — tout dans
l'app, y compris la demande de mot de passe administrateur).

Le démon de surveillance est géré par l'app : il vit et meurt avec elle.
EOF
