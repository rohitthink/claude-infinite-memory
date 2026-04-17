#!/bin/bash
# mds-watchdog.sh
#
# Periodic health check for macOS Spotlight metadata daemon (mds / mds_stores /
# mdworker_shared).  On large or rapidly-changing vaults these processes can
# hang, peg CPU, or hold file handles that block the reconciliation daemon.
#
# Designed to be invoked by launchd every 15 minutes.  Also useful ad-hoc.
#
# What it checks:
#   1. mds / mds_stores CPU usage — alerts if above threshold for long enough
#   2. .metadata_never_index flag file in CLAUDE_BRIDGE_HOME — recreates if missing
#   3. Spotlight metadata cache size — warns if cache is bloated and CPU is high
#   4. Writes a heartbeat timestamp (matches W3 truenas-sync pattern)
#
# Exit codes:
#   0   all clear, or --dry-run
#   1   pathology detected; alert fired
#
# Usage:
#   mds-watchdog.sh [options]
#
#   --dry-run                 print checks without writing state or sending notifications
#   --threshold-cpu N         CPU% threshold (default 90)
#   --threshold-duration-min N  minutes mds must be elevated before alerting (default 5)
#   --restart-mds             (DANGER) kill + restart mds via launchctl kickstart;
#                             requires sudo; triggers a FULL Spotlight reindex

set -uo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  exit 0
fi

# ---- Defaults ----
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
THRESHOLD_CPU=90
THRESHOLD_DURATION_MIN=5
DRY_RUN=0
RESTART_MDS=0

# ---- Parse flags ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)                DRY_RUN=1 ;;
    --threshold-cpu)          shift; THRESHOLD_CPU="${1:?--threshold-cpu requires a value}" ;;
    --threshold-duration-min) shift; THRESHOLD_DURATION_MIN="${1:?--threshold-duration-min requires a value}" ;;
    --restart-mds)            RESTART_MDS=1 ;;
    --help|-h)
      sed -n '2,30p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---- Paths ----
LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG_FILE="${LOG_DIR}/mds-watchdog.log"
HEARTBEAT_FILE="${CLAUDE_BRIDGE_HOME}/sync-state/mds-watchdog-heartbeat.txt"
SPOTLIGHT_FLAG="${CLAUDE_BRIDGE_HOME}/.metadata_never_index"
LOG_MAX_BYTES=1048576  # 1 MB

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  local level="$1"; shift
  local line
  line="$(ts) [mds-watchdog] ${level}: $*"
  echo "$line"
  if [[ $DRY_RUN == 0 ]]; then
    mkdir -p "$LOG_DIR"
    # Rotate log if over LOG_MAX_BYTES
    if [[ -f "$LOG_FILE" ]]; then
      local size
      size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
      if (( size > LOG_MAX_BYTES )); then
        mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
      fi
    fi
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

send_notification() {
  local msg="$1"
  if [[ $DRY_RUN == 0 ]]; then
    osascript -e "display notification \"${msg}\" with title \"Claude Infinite Memory\"" 2>/dev/null || true
  else
    echo "  [dry-run] would send notification: $msg"
  fi
}

# ---- 1. Check mds / mds_stores CPU usage ----
# ps -eo pid,pcpu,etime,comm lists all processes.
# etime format: [[DD-]HH:]MM:SS  — we extract elapsed seconds.
# We alert only if CPU is high AND process has been running long enough to rule out
# a transient burst (e.g., right after a Spotlight import).

etime_to_sec() {
  # Converts ps etime "[[DD-]HH:]MM:SS" to total seconds.
  local raw="${1//[[:space:]]/}"  # strip any surrounding spaces
  [[ -z "$raw" ]] && echo 0 && return
  local days=0 hours=0 mins=0 secs=0
  # Split on dash first (days separator)
  if [[ "$raw" == *-* ]]; then
    days="${raw%%-*}"
    raw="${raw#*-}"
  fi
  IFS=: read -r -a parts <<< "$raw"
  case "${#parts[@]}" in
    3) hours="${parts[0]}"; mins="${parts[1]}"; secs="${parts[2]}" ;;
    2) mins="${parts[0]}"; secs="${parts[1]}" ;;
    1) secs="${parts[0]}" ;;
  esac
  # Force base 10 to avoid octal interpretation of zero-padded values (e.g. "09")
  echo $(( 10#${days:-0} * 86400 + 10#${hours:-0} * 3600 + 10#${mins:-0} * 60 + 10#${secs:-0} ))
}

THRESHOLD_DURATION_SEC=$(( THRESHOLD_DURATION_MIN * 60 ))

# Parse ps: collect (pid, cpu%, elapsed_sec, comm) for mds processes
mds_alert=0
mds_alert_msg=""

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Trim leading whitespace (ps sometimes indents)
  line="${line#"${line%%[! ]*}"}"
  read -r pid pcpu etime comm <<< "$line"
  # On macOS, comm is the full path; match on the basename component
  comm_base="${comm##*/}"
  [[ "$comm_base" =~ ^mds ]] || continue

  # Strip decimal from pcpu (bc not always available; use integer comparison)
  pcpu_int="${pcpu%%.*}"
  [[ "$pcpu_int" =~ ^[0-9]+$ ]] || continue

  elapsed_sec=$(etime_to_sec "$etime")

  log "INFO" "mds process pid=${pid} comm=${comm_base} cpu=${pcpu}% elapsed=${elapsed_sec}s (threshold: cpu>${THRESHOLD_CPU}% for >${THRESHOLD_DURATION_SEC}s)"

  if (( pcpu_int >= THRESHOLD_CPU && elapsed_sec >= THRESHOLD_DURATION_SEC )); then
    mds_alert=1
    mds_alert_msg="Spotlight (${comm_base} pid=${pid}) at ${pcpu}% CPU for ${elapsed_sec}s — may be stuck"
  fi
done < <(ps -eo pid,pcpu,etime,comm 2>/dev/null | tail -n +2)

if [[ $mds_alert == 1 ]]; then
  log "WARN" "$mds_alert_msg"
  send_notification "Spotlight (mds) may be stuck — ${mds_alert_msg}"
fi

# ---- 2. Check + restore .metadata_never_index flag ----
if [[ ! -f "$SPOTLIGHT_FLAG" ]]; then
  log "WARN" "Flag file missing: ${SPOTLIGHT_FLAG} — was removed by cleanup/sync/restore; reinstating"
  if [[ $DRY_RUN == 0 ]]; then
    touch "$SPOTLIGHT_FLAG" 2>/dev/null && \
      log "INFO" "Reinstated: ${SPOTLIGHT_FLAG}" || \
      log "ERROR" "Could not recreate ${SPOTLIGHT_FLAG}"
  else
    echo "  [dry-run] would recreate: $SPOTLIGHT_FLAG"
  fi
else
  log "INFO" "Flag file present: ${SPOTLIGHT_FLAG}"
fi

# Also recreate subdirectory flags that the exclusions-setup script places
for subdir in sync-spool sync-active logs sync-state; do
  subdir_flag="${CLAUDE_BRIDGE_HOME}/${subdir}/.metadata_never_index"
  subdir_path="${CLAUDE_BRIDGE_HOME}/${subdir}"
  [[ -d "$subdir_path" ]] || continue
  if [[ ! -f "$subdir_flag" ]]; then
    log "WARN" "Subdir flag missing: ${subdir_flag} — reinstating"
    if [[ $DRY_RUN == 0 ]]; then
      touch "$subdir_flag" 2>/dev/null || log "ERROR" "Could not recreate ${subdir_flag}"
    else
      echo "  [dry-run] would recreate: $subdir_flag"
    fi
  fi
done

# ---- 3. Check Spotlight metadata cache size ----
# /var/folders/.../C/com.apple.metadata:  launchd-created per-boot temp dirs.
# We check if any of these exceed 10GB AND mds CPU is high.
MDS_CACHE_THRESHOLD_BYTES=$(( 10 * 1024 * 1024 * 1024 ))  # 10 GB

metadata_cache_size=0
if [[ -d /var/folders ]]; then
  # Use find to sum sizes under com.apple.metadata dirs (non-destructive)
  while IFS= read -r cache_dir; do
    [[ -d "$cache_dir" ]] || continue
    dir_size=$(du -sk "$cache_dir" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)
    metadata_cache_size=$(( metadata_cache_size + dir_size ))
  done < <(find /var/folders -type d -name 'com.apple.metadata' 2>/dev/null)
fi

log "INFO" "Spotlight metadata cache estimated size: ${metadata_cache_size} bytes"

if (( metadata_cache_size > MDS_CACHE_THRESHOLD_BYTES && mds_alert == 1 )); then
  cache_gb=$(( metadata_cache_size / 1024 / 1024 / 1024 ))
  msg="Spotlight cache is ${cache_gb}GB and mds CPU is high — possible pathological-file situation. Consider: sudo mdutil -E <vault-path>"
  log "WARN" "$msg"
  send_notification "$msg"
fi

# ---- 4. --restart-mds (explicit opt-in only) ----
if [[ $RESTART_MDS == 1 ]]; then
  log "WARN" "--restart-mds flag set: killing + restarting mds via launchctl kickstart"
  log "WARN" "WARNING: this invalidates the Spotlight index and triggers a FULL reindex. This may take hours on a large vault."
  if [[ $DRY_RUN == 0 ]]; then
    if sudo launchctl kickstart -k system/com.apple.metadata.mds 2>/dev/null; then
      log "INFO" "mds restarted successfully"
    else
      log "ERROR" "mds restart failed (sudo required; run with sudo or grant Full Disk Access)"
    fi
  else
    echo "  [dry-run] would run: sudo launchctl kickstart -k system/com.apple.metadata.mds"
  fi
fi

# ---- 5. Write heartbeat ----
if [[ $DRY_RUN == 0 ]]; then
  mkdir -p "${CLAUDE_BRIDGE_HOME}/sync-state"
  date +%s > "$HEARTBEAT_FILE" 2>/dev/null || true
  log "INFO" "Heartbeat written: $HEARTBEAT_FILE"
else
  echo "  [dry-run] would write heartbeat to: $HEARTBEAT_FILE"
fi

if [[ $mds_alert == 1 ]]; then
  exit 1
fi
exit 0
