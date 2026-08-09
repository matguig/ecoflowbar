#!/bin/bash
# "Pseudo-hibernation" shutdown: saves as much session state as possible,
# then shuts down cleanly. Restore happens at login via ef_restore.sh
# (fr.koa.ecoflow-restore agent). Used by EcoFlowBar's moon button and by
# the daemon's automatic shutdown threshold.
set -u
SNAP="$HOME/Library/Application Support/ecoflow-monitor/snapshot"
mkdir -p "$SNAP"

# 1. tmux sessions — tmux-resurrect if installed, otherwise a best-effort list
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

# 2. Open applications (relaunched at login)
osascript -e 'tell application "System Events" to get name of every application process whose background only is false' 2>/dev/null \
    | tr ',' '\n' | sed 's/^ *//' \
    | grep -vE '^(Finder|EcoFlowBar|app|loginwindow)$' \
    > "$SNAP/apps.txt" || true

# 3. Safari tabs — a readable fallback backup, not reopened automatically
#    (Safari restores its own session; this file is a safety net)
if pgrep -xq Safari; then
    osascript -e 'tell application "Safari" to get URL of every tab of every window' \
        > "$SNAP/safari_tabs.txt" 2>/dev/null || true
fi

# 4. Marker read by ef_restore.sh at the next login
date +%s > "$SNAP/hibernated"

# 5. Graceful shutdown: macOS asks each app to quit cleanly
#    (unsaved documents = a dialog, no silent data loss)
#    EF_NO_SHUTDOWN=1: test mode — everything except the shutdown itself
if [ "${EF_NO_SHUTDOWN:-}" = "1" ]; then
    echo "[dry-run] snapshot written to $SNAP — shutdown skipped"
    rm -f "$SNAP/hibernated"
else
    osascript -e 'tell application "System Events" to shut down'
fi
