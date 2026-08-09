#!/bin/bash
# Restauration de session après une pseudo-hibernation (ef_hibernate.sh).
# Lancé à chaque login par l'agent fr.koa.ecoflow-restore ; ne fait rien
# si aucun marqueur d'hibernation n'est présent.
set -u
SNAP="$HOME/Library/Application Support/ecoflow-monitor/snapshot"
[ -f "$SNAP/hibernated" ] || exit 0
rm -f "$SNAP/hibernated"

# Laisser la session graphique finir de s'ouvrir
sleep 10

# Relancer les applications sauvegardées (-g : sans les mettre au premier plan)
if [ -f "$SNAP/apps.txt" ]; then
    while IFS= read -r app; do
        [ -n "$app" ] && open -ga "$app" 2>/dev/null || true
    done < "$SNAP/apps.txt"
fi

# Restaurer les sessions tmux si tmux-resurrect est installé
if [ "$(cat "$SNAP/tmux.txt" 2>/dev/null)" = "resurrect" ]; then
    RESTORE="$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh"
    if [ -x "$RESTORE" ] && command -v tmux >/dev/null 2>&1; then
        tmux has-session 2>/dev/null || tmux new-session -d -s restauree
        "$RESTORE" || true
    fi
fi

osascript -e 'display notification "Session restaurée après hibernation" with title "EcoFlow"' 2>/dev/null || true
