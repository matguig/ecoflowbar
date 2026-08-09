#!/bin/bash
# Daemon launcher for the distributed app: embedded standalone Python,
# no system prerequisites. The exec preserves stdin (supervision pipe).
set -euo pipefail
RES="$(cd "$(dirname "$0")" && pwd)"
exec "$RES/python/bin/python3" "$RES/scripts/ef_monitor.py"
