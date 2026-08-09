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

# Relancer les applications sauvegardées (-g : sans les mettre au premier plan),
# en les espaçant pour éviter le pic de charge au login
if [ -f "$SNAP/apps.txt" ]; then
    while IFS= read -r app; do
        [ -n "$app" ] && open -ga "$app" 2>/dev/null || true
        sleep 1
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

LANG_CODE=$(defaults read -g AppleLanguages 2>/dev/null | grep -oE '"[a-z]{2}' | head -1 | tr -d '"')
case "$LANG_CODE" in
    fr) MSG="Session restaurée après hibernation" ;;
    de) MSG="Sitzung nach Ruhezustand wiederhergestellt" ;;
    ja) MSG="休止状態からセッションを復元しました" ;;
    zh) MSG="已从休眠恢复会话" ;;
    *)  MSG="Session restored after hibernation" ;;
esac
osascript -e "display notification \"$MSG\" with title \"EcoFlow\"" 2>/dev/null || true
