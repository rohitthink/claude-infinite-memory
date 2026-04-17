#!/bin/bash
# truenas-sync-watchdog.sh
#
# Checks that the truenas-sync daemon is making backup progress.
# Fires a macOS notification if the heartbeat is stale while the vault
# has recent write activity — indicating backups are silently frozen.
#
# Run via launchd every 15 minutes (see com.example.truenas-sync-watchdog.plist.template).
#
# Exit codes:
#   0   heartbeat fresh, or no vault activity (nothing to alert)
#   1   stale heartbeat with live vault activity — alert fired

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
HEARTBEAT_FILE="${CLAUDE_BRIDGE_HOME}/sync-state/truenas-sync-heartbeat.txt"
FAILURE_LOG="${CLAUDE_BRIDGE_HOME}/logs/truenas-sync-watchdog-alerts.log"

STALE_THRESHOLD_SEC=1800  # 30 minutes
VAULT_ACTIVITY_MIN=30     # look for vault files modified in last N minutes

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_alert() {
  mkdir -p "$(dirname "$FAILURE_LOG")"
  echo "$(ts) [truenas-sync-watchdog] ALERT: $1" >> "$FAILURE_LOG" 2>/dev/null || true
}

send_notification() {
  local msg="$1"
  osascript -e "display notification \"${msg}\" with title \"Claude Infinite Memory\"" 2>/dev/null || true
}

# No heartbeat file yet — daemon hasn't run a successful sync; skip silently.
if [[ ! -f "$HEARTBEAT_FILE" ]]; then
  exit 0
fi

last_hb=$(tr -d '[:space:]' < "$HEARTBEAT_FILE" 2>/dev/null || echo "")
if [[ ! "$last_hb" =~ ^[0-9]+$ ]]; then
  exit 0
fi

now=$(date +%s)
age=$(( now - last_hb ))

if (( age <= STALE_THRESHOLD_SEC )); then
  exit 0
fi

# Heartbeat is stale. Check for recent vault write activity.
if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
  exit 0
fi

recent_files=$(find "$VAULT" -type f -mmin -"$VAULT_ACTIVITY_MIN" 2>/dev/null | wc -l | tr -d ' ')
if (( recent_files <= 0 )); then
  exit 0
fi

# Stale backup + active vault → alert.
age_min=$(( age / 60 ))
msg="TrueNAS backup stale ${age_min}m (${recent_files} vault file(s) changed in last ${VAULT_ACTIVITY_MIN}m)"

log_alert "$msg"
send_notification "$msg"
exit 1
