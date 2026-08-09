#!/bin/bash
# Lanceur du démon pour l'app distribuée : Python autonome embarqué,
# aucun prérequis système. L'exec préserve le stdin (pipe de supervision).
set -euo pipefail
RES="$(cd "$(dirname "$0")" && pwd)"
exec "$RES/python/bin/python3" "$RES/scripts/ef_monitor.py"
