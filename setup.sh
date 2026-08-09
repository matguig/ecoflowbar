#!/bin/bash
# Installation de l'indicateur batterie EcoFlow pour le Mac mini.
# Idempotent : relançable sans risque après un git pull ou un changement de config.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_LABEL="fr.koa.ecoflow-monitor"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

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
</dict>
</plist>
PLIST
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    "$DIR/app/EcoFlowBar.swift" -o "$BAR_APP/Contents/MacOS/EcoFlowBar"
codesign --force --sign - "$BAR_APP" 2>/dev/null || true

sed "s|__PROJECT_DIR__|$DIR|g" "$DIR/launchd/fr.koa.ecoflow-bar.plist.in" \
    > "$HOME/Library/LaunchAgents/fr.koa.ecoflow-bar.plist"
launchctl bootout "gui/$(id -u)/fr.koa.ecoflow-bar" 2>/dev/null || true
pkill -f EcoFlowBar.app 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/fr.koa.ecoflow-bar.plist"

echo "==> Wrapper applicatif (déclaration Bluetooth pour macOS)"
APP="$DIR/EcoFlowMonitor.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>fr.koa.ecoflow-monitor</string>
    <key>CFBundleName</key>
    <string>EcoFlowMonitor</string>
    <key>CFBundleExecutable</key>
    <string>ecoflow-monitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Lecture de l'état de la batterie EcoFlow en Bluetooth local.</string>
</dict>
</plist>
PLIST
cat > "$APP/Contents/MacOS/ecoflow-monitor" <<SH
#!/bin/bash
# Lancé par launchd ; python en processus fils pour que macOS attribue
# l'accès Bluetooth à ce bundle (pas d'exec : l'attribution suivrait le binaire).
"$DIR/.venv/bin/python" "$DIR/scripts/ef_monitor.py"
SH
chmod +x "$APP/Contents/MacOS/ecoflow-monitor"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "==> LaunchAgent (démon de surveillance)"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod +x "$DIR/scripts/ef_hibernate.sh" "$DIR/scripts/ef_restore.sh"
sed "s|__PROJECT_DIR__|$DIR|g; s|__HOME__|$HOME|g" \
    "$DIR/launchd/$PLIST_LABEL.plist.in" > "$PLIST_DEST"
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo "==> LaunchAgent (restauration de session post-hibernation)"
sed "s|__PROJECT_DIR__|$DIR|g" "$DIR/launchd/fr.koa.ecoflow-restore.plist.in" \
    > "$HOME/Library/LaunchAgents/fr.koa.ecoflow-restore.plist"
launchctl bootout "gui/$(id -u)/fr.koa.ecoflow-restore" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/fr.koa.ecoflow-restore.plist"


cat <<'EOF'

Installation terminée. Étapes restantes (une seule fois) :

1. Identifiant EcoFlow (nécessite Internet, mot de passe non conservé) :
     .venv/bin/python scripts/ef_login.py

2. Appairage de la batterie (allumée, à portée Bluetooth) :
     .venv/bin/python scripts/ef_scan.py

3. (Optionnel — requis pour le mode éco et l'extinction automatiques)
     sudo install -m 440 config/sudoers-ecoflow /etc/sudoers.d/ecoflow-monitor
     sudo visudo -c

4. Relancer le démon pour prendre en compte la config :
     launchctl kickstart -k gui/$(id -u)/fr.koa.ecoflow-monitor

macOS demandera l'autorisation Bluetooth au premier scan : accepter.
EOF
