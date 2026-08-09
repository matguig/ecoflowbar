#!/bin/bash
# Session restore after a pseudo-hibernation (ef_hibernate.sh).
# Run at every login by the fr.koa.ecoflow-restore agent; does nothing
# if no hibernation marker is present.
set -u
SNAP="$HOME/Library/Application Support/ecoflow-monitor/snapshot"
[ -f "$SNAP/hibernated" ] || exit 0
rm -f "$SNAP/hibernated"

# Let the graphical session finish opening
sleep 10

# Relaunch the saved applications (-g: without bringing them to the foreground),
# spacing them out to avoid the load spike at login
if [ -f "$SNAP/apps.txt" ]; then
    while IFS= read -r app; do
        [ -n "$app" ] && open -ga "$app" 2>/dev/null || true
        sleep 1
    done < "$SNAP/apps.txt"
fi

# Restore tmux sessions if tmux-resurrect is installed
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
    es) MSG="Sesión restaurada tras la hibernación" ;;
    ja) MSG="休止状態からセッションを復元しました" ;;
    zh) MSG="已从休眠恢复会话" ;;
    *)  MSG="Session restored after hibernation" ;;
esac
osascript -e "display notification \"$MSG\" with title \"EcoFlow\"" 2>/dev/null || true
