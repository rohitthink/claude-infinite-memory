#!/bin/bash
# obsidian-truenas-sync.sh
#
# Real-time backup of the Obsidian vault to a remote host (e.g., TrueNAS, a
# second Mac, any SSH-reachable machine) via rsync-over-SSH.
#
# Flow:
#   vault source   -> rsync-SSH ->   $CLAUDE_BRIDGE_TRUENAS_HOST:$CLAUDE_BRIDGE_TRUENAS_PATH
#
# Modes:
#   --once            Single push, exit. Good for cron / manual runs.
#   --watch           fswatch-driven continuous mode; debounced so we rsync at
#                     most once per DEBOUNCE_SEC (default 10s) of filesystem
#                     quiet. Avoids thrashing on rapid Obsidian autosaves.
#   --help            Print usage.
#
# Flags (combinable with --once or --watch):
#   --force-delete    BYPASS source-sanity + deletion-threshold guards. Use
#                     only for deliberate wipes (vault rename, etc.). Logged
#                     loudly.
#   --no-delete       Run rsync WITHOUT --delete at all (accumulator mode).
#
# Safety guards (all configurable via env):
#   MIN_MD_FILES      (default 50)    minimum .md count in source
#   MIN_VAULT_BYTES   (default 100000) minimum total size of source, bytes
#   MAX_DELETE_PCT    (default 20)    abort if rsync would delete >N% of remote
#
# A two-pass scheme is used: a dry-run with --stats reports how many files
# would be deleted; the real run is aborted if that count exceeds MAX_DELETE_PCT
# of the current remote file count. This defends against a transiently-empty
# vault (e.g., unmounted external drive, rename in flight) wiping the backup.
#
# Lock:
#   LOCAL lock at $CLAUDE_BRIDGE_HOME/sync-active/truenas-sync.lock (mkdir).
#   Distinct from vault-sync.lock (that one serializes Claude-side writes;
#   this one just serializes concurrent remote pushes).
#
# SSH probe:
#   Non-interactive SSH probe before every rsync. On probe failure we log
#   and bail quickly the next --watch debounce cycle (or next cron tick)
#   will retry naturally.
#
# Hard timeout:
#   rsync wrapped in perl alarm (300s). Protects against hung SSH sessions.
#
# Logging:
#   logs/truenas-sync.log, rotated at 1MB -> .log.1
#   One structured summary per run:
#     YYYY-MM-DD HH:MM:SS [truenas-sync] mode=X duration=Ys exit=Z bytes-xferred=N md_count=M total_bytes=B would_delete=D
#
# Exit codes:
#   0   sync completed cleanly
#   1   fatal pre-flight failure (vault missing, lock held, config incomplete, etc.)
#   2   SSH probe failed (remote unreachable)
#   3   rsync failed / timed out
#   4   bad flag
#   5   source-sanity guard tripped
#   6   deletion-threshold guard tripped

set -uo pipefail

# ---- Config (override via env) ----
CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
REMOTE_HOST="${CLAUDE_BRIDGE_TRUENAS_HOST:-}"
REMOTE_PATH="${CLAUDE_BRIDGE_TRUENAS_PATH:-}"

LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/truenas-sync.log"
LOG_MAX_BYTES=$((1024 * 1024))  # 1 MB
LOCK_DIR="${CLAUDE_BRIDGE_HOME}/sync-active"
LOCK="$LOCK_DIR/truenas-sync.lock"
LOCK_WAIT_SEC=60

FSWATCH="/opt/homebrew/bin/fswatch"
RSYNC="/usr/bin/rsync"
PERL="/usr/bin/perl"
SSH="/usr/bin/ssh"

RSYNC_TIMEOUT_SEC=300
DEBOUNCE_SEC=10

# Safety-guard defaults (env-overridable)
MIN_MD_FILES="${MIN_MD_FILES:-50}"
MIN_VAULT_BYTES="${MIN_VAULT_BYTES:-100000}"
MAX_DELETE_PCT="${MAX_DELETE_PCT:-20}"

# Flag state
FORCE_DELETE=0
NO_DELETE=0
MODE=""

# Stats captured during the run (for the final summary line)
STAT_MD_COUNT=""
STAT_TOTAL_BYTES=""
STAT_WOULD_DELETE=""

# ---- Helpers ----

usage() {
  cat <<'EOF'
obsidian-truenas-sync.sh — real-time vault backup to a remote host

Usage:
  obsidian-truenas-sync.sh --once [flags]   Single rsync push, exit.
  obsidian-truenas-sync.sh --watch [flags]  fswatch-driven debounced push loop.
  obsidian-truenas-sync.sh --help           Show this help.

Flags:
  --force-delete    Bypass source-sanity + deletion-threshold guards.
                    Logged loudly. Use only for deliberate wipes.
  --no-delete       Run rsync WITHOUT --delete (accumulator mode).

Required env (set via claude-infinite-memory.env):
  CLAUDE_BRIDGE_VAULT          local vault path
  CLAUDE_BRIDGE_TRUENAS_HOST   SSH host (must be passwordless-capable)
  CLAUDE_BRIDGE_TRUENAS_PATH   remote path (trailing slash recommended)

Optional:
  CLAUDE_BRIDGE_HOME           defaults to ~/.claude
  MIN_MD_FILES                 min .md count in source (default 50)
  MIN_VAULT_BYTES              min total vault size in bytes (default 100000)
  MAX_DELETE_PCT               abort if rsync would delete >N% of remote (default 20)
EOF
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_init() {
  mkdir -p "$LOG_DIR"
  if [[ -f "$LOG" ]]; then
    local size
    size=$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_BYTES )); then
      mv -f "$LOG" "$LOG.1"
    fi
  fi
  touch "$LOG"
}

log_line() {
  echo "$(ts) [truenas-sync] $1" >> "$LOG"
}

log_abort() {
  # Write to log AND stderr so launchd/systemd stderr log captures every abort.
  echo "$(ts) [truenas-sync] $1" >> "$LOG"
  echo "$(ts) [truenas-sync] $1" >&2
}

log_summary() {
  # $1=mode $2=duration $3=exit $4=bytes
  log_line "mode=$1 duration=${2}s exit=$3 bytes-xferred=${4} md_count=${STAT_MD_COUNT:-NA} total_bytes=${STAT_TOTAL_BYTES:-NA} would_delete=${STAT_WOULD_DELETE:-NA}"
}

acquire_lock() {
  mkdir -p "$LOCK_DIR"
  local waited=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    if (( waited >= LOCK_WAIT_SEC )); then
      log_line "lock held by pid=$(cat "$LOCK/pid" 2>/dev/null || echo ?); skipping run"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo $$ > "$LOCK/pid" 2>/dev/null || true
  trap release_lock EXIT INT TERM
  return 0
}

release_lock() {
  rm -rf "$LOCK" 2>/dev/null || true
}

probe_ssh() {
  # Use a raw TCP connect (port 22) so the probe works even if the key has a
  # forced command (e.g. rrsync or a custom wrapper) that disallows
  # interactive commands such as "true".
  #
  # IMPORTANT: REMOTE_HOST may be an ssh config alias (e.g. "truenas") that
  # doesn't resolve via DNS. Perl's IO::Socket::INET only speaks hostnames and
  # IPs — it ignores ~/.ssh/config. Use `ssh -G` (local-only, no network) to
  # resolve the alias to its real hostname/IP first, then TCP-probe that.
  local real_host
  real_host=$("$SSH" -G "$REMOTE_HOST" 2>/dev/null | awk '/^hostname / {print $2; exit}')
  [[ -z "$real_host" ]] && real_host="$REMOTE_HOST"
  "$PERL" -MIO::Socket::INET -e '
    alarm 5;
    my $s = IO::Socket::INET->new(PeerAddr=>$ARGV[0], PeerPort=>22, Timeout=>3)
      or exit 1;
    close $s;
    exit 0;
  ' "$real_host" 2>/dev/null
}

check_vault() {
  if [[ -z "$VAULT" || ! -d "$VAULT" ]]; then
    log_line "abort: vault not set or not mounted at '$VAULT'"
    return 1
  fi
  return 0
}

check_config() {
  if [[ -z "$REMOTE_HOST" || -z "$REMOTE_PATH" ]]; then
    log_line "abort: CLAUDE_BRIDGE_TRUENAS_HOST or CLAUDE_BRIDGE_TRUENAS_PATH not set"
    return 1
  fi
  return 0
}

# Count .md files in source
count_md_files() {
  find "$VAULT" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

# Count all files in source
count_all_files() {
  find "$VAULT" -type f 2>/dev/null | wc -l | tr -d ' '
}

# Total bytes of source (portable: sum file sizes via find+stat)
vault_total_bytes() {
  local total=0 size
  while IFS= read -r f; do
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    total=$(( total + size ))
  done < <(find "$VAULT" -type f 2>/dev/null)
  echo "$total"
}

# Source-sanity guard. Returns 0 if source is safe, non-zero if it tripped.
# Populates STAT_MD_COUNT and STAT_TOTAL_BYTES as a side-effect.
source_sanity_check() {
  local md total all
  md=$(count_md_files)
  all=$(count_all_files)
  total=$(vault_total_bytes)
  STAT_MD_COUNT="$md"
  STAT_TOTAL_BYTES="$total"

  if (( FORCE_DELETE == 1 )); then
    log_line "WARNING: --force-delete flag set; source-sanity guards BYPASSED"
    log_line "  md_count=$md total_bytes=$total all_files=$all"
    return 0
  fi

  if (( all == 0 )); then
    log_abort "ABORT: source sanity check failed (reason=empty_vault) md_count=$md bytes=$total would_delete=NA"
    return 1
  fi
  if (( md < MIN_MD_FILES )); then
    log_abort "ABORT: source sanity check failed (reason=md_count_floor) md_count=$md bytes=$total would_delete=NA"
    return 1
  fi
  if (( total < MIN_VAULT_BYTES )); then
    log_abort "ABORT: source sanity check failed (reason=bytes_floor) md_count=$md bytes=$total would_delete=NA"
    return 1
  fi
  return 0
}

# Core rsync invocation. Populates a tempfile with rsync output; prints the
# tempfile path on stdout. Caller is responsible for rm.
#
# $1 = "dry" or "real"
# $2 = "with-delete" or "no-delete"
_rsync_run() {
  local mode="$1"
  local delete_mode="$2"
  local tmp
  tmp=$(mktemp -t truenas-sync.XXXXXX)

  local -a rsync_args=(
    -a --partial --human-readable --stats
    --exclude='.obsidian/workspace*'
    --exclude='.obsidian/cache*'
    --exclude='.Trash/'
    --exclude='.DS_Store'
    -e "$SSH -o BatchMode=yes -o ConnectTimeout=10"
  )
  if [[ "$delete_mode" == "with-delete" ]]; then
    rsync_args+=(--delete)
  fi
  if [[ "$mode" == "dry" ]]; then
    rsync_args+=(-n)
  fi
  rsync_args+=("${VAULT%/}/" "$REMOTE_HOST:$REMOTE_PATH")

  "$PERL" -e 'alarm shift @ARGV; exec @ARGV' "$RSYNC_TIMEOUT_SEC" \
    "$RSYNC" "${rsync_args[@]}" > "$tmp" 2>&1
  local rc=$?

  echo "$tmp"
  return $rc
}

# Parse "Number of deleted files: N" from rsync --stats output.
parse_would_delete() {
  local out="$1"
  local n
  n=$(awk -F: '/Number of deleted files/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$out" 2>/dev/null)
  if [[ -z "$n" ]]; then
    # grep -c returns exit 1 when no matches, so suppress and default to 0.
    n=$(grep -c '^deleting ' "$out" 2>/dev/null)
    [[ -z "$n" ]] && n=0
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

# Remote file count proxy: parse the rsync dry-run --stats line
# "Number of files: N". That's the union of source and receiver file lists,
# so it is an upper bound on remote count — acceptable as a denominator
# for the deletion-ratio guard. Avoids needing an interactive SSH channel
# (which a forced-command like rrsync rejects).
remote_file_count() {
  local out="$1"
  local n
  n=$(awk '/^Number of files:/ {
             sub(/^Number of files:[ \t]*/, "")
             gsub(",", "")
             split($0, a, " ")
             v = a[1]; gsub(/[^0-9]/, "", v)
             if (v != "") { print v; exit }
           }' "$out" 2>/dev/null)
  [[ -z "$n" ]] && n=0
  echo "$n"
}

# Extract bytes transferred from a rsync --stats output file.
parse_bytes_xferred() {
  local out="$1"
  local bytes
  bytes=$(awk '
    /^Total transferred file size:/ {
      sub(/^Total transferred file size:[ \t]*/, "")
      n = $0
      gsub(",", "", n)
      split(n, a, " ")
      v = a[1]; gsub(/[^0-9]/, "", v)
      if (v != "") { print v; exit }
    }' "$out" 2>/dev/null)
  if [[ -z "$bytes" ]]; then
    bytes=$(awk '/^sent / { gsub(",","",$2); v=$2; gsub(/[^0-9]/, "", v); print v; exit }' "$out" 2>/dev/null)
  fi
  [[ -z "$bytes" ]] && bytes=0
  echo "$bytes"
}

# Deletion-threshold guard. Runs a dry-run rsync to compute the number of
# would-be deletions, then compares against MAX_DELETE_PCT of the remote file
# count. Returns 0 if safe, non-zero if the guard trips.
# Populates STAT_WOULD_DELETE as a side-effect.
deletion_threshold_check() {
  local delete_mode="$1"

  if [[ "$delete_mode" != "with-delete" ]]; then
    STAT_WOULD_DELETE=0
    return 0
  fi
  if (( FORCE_DELETE == 1 )); then
    log_line "WARNING: --force-delete flag set; deletion-threshold guard BYPASSED"
    local tmp
    tmp=$(_rsync_run dry with-delete) || true
    STAT_WOULD_DELETE=$(parse_would_delete "$tmp")
    rm -f "$tmp"
    log_line "  (informational) would_delete=$STAT_WOULD_DELETE"
    return 0
  fi

  local tmp rc would remote pct
  tmp=$(_rsync_run dry with-delete)
  rc=$?
  would=$(parse_would_delete "$tmp")
  STAT_WOULD_DELETE="$would"
  remote=$(remote_file_count "$tmp")

  if (( rc != 0 )); then
    log_line "ABORT: dry-run rsync failed (rc=$rc); tail:"
    tail -n 8 "$tmp" 2>/dev/null | while IFS= read -r line; do
      log_line "  $line"
    done
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"

  if (( remote <= 0 )); then
    log_line "deletion-threshold: remote file count is $remote; skipping ratio check (initial seed?)"
    return 0
  fi

  pct=$(( 100 * would / remote ))
  log_line "deletion-threshold: would_delete=$would remote_files=$remote pct=${pct}%"
  if (( pct > MAX_DELETE_PCT )); then
    log_abort "ABORT: source sanity check failed (reason=delete_pct_floor) md_count=${STAT_MD_COUNT:-NA} bytes=${STAT_TOTAL_BYTES:-NA} would_delete=${pct}%"
    log_line "  (deletion ratio ${pct}% > MAX_DELETE_PCT=${MAX_DELETE_PCT}% — would delete $would of $remote files)"
    log_line "  If this is intentional (vault rename / cleanup), re-run with --force-delete"
    return 1
  fi
  return 0
}

# Run the REAL rsync (not dry-run). Writes stats to a tempfile, prints
# bytes-xferred on stdout, returns rsync's exit code.
run_rsync_real() {
  local delete_mode="$1"
  local tmp rc bytes
  tmp=$(_rsync_run real "$delete_mode")
  rc=$?
  bytes=$(parse_bytes_xferred "$tmp")

  if (( rc != 0 )); then
    log_line "rsync output tail:"
    tail -n 8 "$tmp" 2>/dev/null | while IFS= read -r line; do
      log_line "  $line"
    done
  fi
  rm -f "$tmp"

  echo "$bytes"
  return $rc
}

do_sync() {
  local mode="$1"
  local start end duration rc bytes delete_mode

  STAT_MD_COUNT=""
  STAT_TOTAL_BYTES=""
  STAT_WOULD_DELETE=""

  if ! check_config; then
    log_summary "$mode" 0 1 0
    return 1
  fi
  if ! check_vault; then
    log_summary "$mode" 0 1 0
    return 1
  fi

  if (( NO_DELETE == 1 )); then
    delete_mode="no-delete"
  else
    delete_mode="with-delete"
  fi

  if ! source_sanity_check; then
    log_summary "$mode" 0 5 0
    return 5
  fi

  if ! probe_ssh; then
    log_summary "$mode" 0 2 0
    return 2
  fi

  if ! deletion_threshold_check "$delete_mode"; then
    log_summary "$mode" 0 6 0
    return 6
  fi

  start=$(date +%s)
  bytes=$(run_rsync_real "$delete_mode")
  rc=$?
  end=$(date +%s)
  duration=$((end - start))

  log_summary "$mode" "$duration" "$rc" "${bytes:-0}"
  (( rc == 0 )) || return 3
  return 0
}

# ---- Modes ----

mode_once() {
  log_init
  if ! acquire_lock; then
    return 1
  fi
  do_sync once
  return $?
}

mode_watch() {
  log_init
  if ! acquire_lock; then
    return 1
  fi

  if [[ ! -x "$FSWATCH" ]]; then
    log_line "abort: fswatch not found at $FSWATCH (install with: brew install fswatch)"
    return 1
  fi
  if ! check_config; then
    return 1
  fi
  if ! check_vault; then
    return 1
  fi

  log_line "mode=watch starting (debounce=${DEBOUNCE_SEC}s force_delete=${FORCE_DELETE} no_delete=${NO_DELETE})"

  do_sync watch-boot || true

  local pending=0
  while true; do
    if IFS= read -r -t "$DEBOUNCE_SEC" _event; then
      pending=1
    else
      if (( pending == 1 )); then
        do_sync watch || true
        pending=0
      fi
    fi
  done < <("$FSWATCH" \
              --latency=1 \
              --exclude='\.obsidian/workspace' \
              --exclude='\.obsidian/cache' \
              --exclude='\.Trash' \
              --exclude='\.DS_Store' \
              "$VAULT" 2>>"$LOG")
}

# ---- Entrypoint ----

main() {
  if (( $# < 1 )); then
    usage >&2
    return 4
  fi
  while (( $# > 0 )); do
    case "$1" in
      --once)         MODE="once" ;;
      --watch)        MODE="watch" ;;
      --help|-h)      usage; return 0 ;;
      --force-delete) FORCE_DELETE=1 ;;
      --no-delete)    NO_DELETE=1 ;;
      *)              usage >&2; return 4 ;;
    esac
    shift
  done

  case "$MODE" in
    once)  mode_once ;;
    watch) mode_watch ;;
    *)     usage >&2; return 4 ;;
  esac
}

main "$@"
