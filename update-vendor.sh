#!/bin/bash
# Updates vendor/eflib from the upstream rabits/ha-ef-ble repository.
# Use this if an EcoFlow firmware update breaks the BLE protocol.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Fetching ha-ef-ble (upstream)"
git clone --depth 1 --quiet https://github.com/rabits/ha-ef-ble.git "$TMP/ha-ef-ble"

echo "==> Replacing vendor/eflib"
rsync -a --delete --exclude "LICENSE" \
    "$TMP/ha-ef-ble/custom_components/ef_ble/eflib/" "$DIR/vendor/eflib/"
cp "$TMP/ha-ef-ble/LICENSE" "$DIR/vendor/eflib/LICENSE"

echo "==> Changes:"
git -C "$DIR" status --short vendor/eflib | head -20 || true

cat <<'EOF'

Review, then apply:
  git diff --stat vendor/eflib
  .venv/bin/python -c "import sys; sys.path.insert(0,'vendor'); import eflib"
  launchctl kickstart -k gui/$(id -u)/fr.koa.ecoflow-monitor
EOF
