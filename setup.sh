#!/bin/bash
# Installs the EcoFlow battery indicator for the Mac mini.
# Idempotent: safe to re-run after a git pull or a config change.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Python environment"
if [ ! -x "$DIR/.venv/bin/python" ]; then
    python3 -m venv "$DIR/.venv"
fi
"$DIR/.venv/bin/pip" install -q bleak bleak-retry-connector ecdsa pycryptodome protobuf aiohttp

echo "==> EcoFlowBar (menu bar app, Stats-style)"
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
    <string>Discovers and pairs your EcoFlow battery over Bluetooth.</string>
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

echo "==> Cleaning up old agents (daemon is now managed by the app)"
launchctl bootout "gui/$(id -u)/fr.koa.ecoflow-monitor" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/fr.koa.ecoflow-monitor.plist"
rm -rf "$DIR/EcoFlowMonitor.app"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
chmod +x "$DIR/scripts/ef_hibernate.sh" "$DIR/scripts/ef_restore.sh"

echo "==> LaunchAgent (session restore after hibernation)"
sed "s|__PROJECT_DIR__|$DIR|g" "$DIR/launchd/fr.koa.ecoflow-restore.plist.in" \
    > "$HOME/Library/LaunchAgents/fr.koa.ecoflow-restore.plist"
launchctl bootout "gui/$(id -u)/fr.koa.ecoflow-restore" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/fr.koa.ecoflow-restore.plist"


cat <<'EOF'

Installation complete.

The EcoFlowBar app is running: the setup assistant opens on first launch
(EcoFlow account, Bluetooth pairing, permissions — everything happens in
the app, including the administrator password prompt).

The monitoring daemon is managed by the app: it lives and dies with it.
EOF
