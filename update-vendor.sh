#!/bin/bash
# Met à jour vendor/eflib depuis le dépôt amont rabits/ha-ef-ble.
# À utiliser si une mise à jour firmware EcoFlow casse le protocole BLE.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Récupération de ha-ef-ble (amont)"
git clone --depth 1 --quiet https://github.com/rabits/ha-ef-ble.git "$TMP/ha-ef-ble"

echo "==> Remplacement de vendor/eflib"
rsync -a --delete --exclude "LICENSE" \
    "$TMP/ha-ef-ble/custom_components/ef_ble/eflib/" "$DIR/vendor/eflib/"
cp "$TMP/ha-ef-ble/LICENSE" "$DIR/vendor/eflib/LICENSE"

echo "==> Changements :"
git -C "$DIR" status --short vendor/eflib | head -20 || true

cat <<'EOF'

Vérifier puis appliquer :
  git diff --stat vendor/eflib
  .venv/bin/python -c "import sys; sys.path.insert(0,'vendor'); import eflib"
  launchctl kickstart -k gui/$(id -u)/fr.koa.ecoflow-monitor
EOF
