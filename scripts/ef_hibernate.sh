#!/bin/bash
# Extinction "pseudo-hibernation" : sauvegarde un maximum d'état de session,
# puis extinction propre. La restauration est faite au login par ef_restore.sh
# (agent fr.koa.ecoflow-restore). Utilisé par le bouton lune d'EcoFlowBar et
# par le palier d'extinction automatique du démon.
set -u
SNAP="$HOME/Library/Application Support/ecoflow-monitor/snapshot"
mkdir -p "$SNAP"

# 1. Sessions tmux — tmux-resurrect si installé, sinon liste best-effort
if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
    RESURRECT="$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"
    if [ -x "$RESURRECT" ]; then
        "$RESURRECT" quiet || true
        echo "resurrect" > "$SNAP/tmux.txt"
    else
        tmux list-windows -a \
            -F '#{session_name}:#{window_index} #{pane_current_path} #{pane_current_command}' \
            > "$SNAP/tmux.txt" 2>/dev/null || true
    fi
fi

# 2. Applications ouvertes (relancées au login)
osascript -e 'tell application "System Events" to get name of every application process whose background only is false' 2>/dev/null \
    | tr ',' '\n' | sed 's/^ *//' | grep -vE '^(Finder|EcoFlowBar)$' \
    > "$SNAP/apps.txt" || true

# 3. Onglets Safari — sauvegarde de secours consultable, non rouverte d'office
#    (Safari restaure lui-même sa session ; ce fichier est un filet)
if pgrep -xq Safari; then
    osascript -e 'tell application "Safari" to get URL of every tab of every window' \
        > "$SNAP/safari_tabs.txt" 2>/dev/null || true
fi

# 4. Marqueur lu par ef_restore.sh au prochain login
date +%s > "$SNAP/hibernated"

# 5. Extinction aimable : macOS demande à chaque app de quitter proprement
#    (documents non enregistrés = boîte de dialogue, pas de perte silencieuse)
osascript -e 'tell application "System Events" to shut down'
