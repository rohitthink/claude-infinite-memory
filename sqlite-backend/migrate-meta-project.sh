#!/bin/bash
# migrate-meta-project.sh  One-time migration: parse existing Session Log and
# Technical Learnings markdown files into the SQLite staging DB.
#
# Sources:
#   $VAULT/07 - Claude Knowledge/Session Log - *.md   (per-device files)
#   $VAULT/07 - Claude Knowledge/Session Log.md        (canonical, if present)
#   $VAULT/07 - Claude Knowledge/Technical Learnings.md
#
# After successful import, renames each source file to *.pre-sqlite-backup
# so the originals are preserved (non-destructive). Reruns are idempotent:
# ingest.sh uses INSERT OR IGNORE (ON CONFLICT DO NOTHING) via session_id
# dedup, and the synthesized session_id is deterministic (sha1 of heading slug)
# so the same heading always maps to the same key.
#
# Exit codes:
#   0 ok, 1 missing dep / DB / vault, 2 nothing to migrate

set -uo pipefail

CLAUDE_BRIDGE_HOME="${CLAUDE_BRIDGE_HOME:-$HOME/.claude}"
BACKEND_DIR="${CLAUDE_BRIDGE_HOME}/sqlite-backend"
DB="$BACKEND_DIR/vault-staging.db"
INGEST_SH="$BACKEND_DIR/ingest.sh"
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
KNOWLEDGE_DIR="$VAULT/07 - Claude Knowledge"

LOG_DIR="${CLAUDE_BRIDGE_HOME}/logs"
LOG="$LOG_DIR/sqlite-backend.log"

SQLITE=/usr/bin/sqlite3
SQLITE_BUSY_MS=30000

mkdir -p "$LOG_DIR" "$BACKEND_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [migrate-meta-$$] $*" >> "$LOG"; }
info() { echo "[migrate-meta-project] $*"; log "$*"; }
warn() { echo "[migrate-meta-project] WARN: $*" >&2; log "WARN: $*"; }
die()  { echo "[migrate-meta-project] ERROR: $*" >&2; log "ERROR: $*"; exit 1; }

# ---- Dependency checks ----
command -v jq  >/dev/null 2>&1 || die "jq not found in PATH"
[[ -x "$SQLITE" ]]             || die "sqlite3 not executable at $SQLITE"
[[ -x "$INGEST_SH" ]]         || die "ingest.sh not found/executable at $INGEST_SH"
[[ -n "$VAULT" && -d "$VAULT" ]] || die "CLAUDE_BRIDGE_VAULT not set or not a directory: $VAULT"
[[ -d "$KNOWLEDGE_DIR" ]]      || die "knowledge dir not found: $KNOWLEDGE_DIR"

# ---- Utility: make a slug + sha1-based synthetic session_id ----
# Deterministic: same heading text → same session_id → idempotent on rerun.
make_session_id() {
  local heading="$1"
  # lower-case, replace non-alphanumeric runs with '-', strip leading/trailing '-'
  local slug
  slug=$(printf '%s' "$heading" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
  local sha
  sha=$(printf '%s' "$slug" | shasum 2>/dev/null | cut -c1-16 || \
        printf '%s' "$slug" | openssl sha1 2>/dev/null | awk '{print $NF}' | cut -c1-16 || \
        printf 'fallback-%s' "${slug:0:16}")
  printf 'migrated-%s' "$sha"
}

# ---- Utility: send a JSON payload to ingest.sh ----
ingest_payload() {
  local payload="$1"
  if ! printf '%s\n' "$payload" | "$INGEST_SH" >> "$LOG" 2>&1; then
    warn "ingest.sh failed for payload: ${payload:0:120}"
    return 1
  fi
  return 0
}

# ---- Parse and ingest one Session Log file ----
# Arg $1: path to the markdown file
# Arg $2: hostname (inferred from filename; empty = 'unknown')
ingest_session_log_file() {
  local filepath="$1"
  local hostname="${2:-unknown}"
  local count=0

  [[ -f "$filepath" ]] || return 0

  info "parsing session log: $filepath (hostname=$hostname)"

  # State machine: scan for ## YYYY-MM-DD — Title headings.
  # Within each heading block, collect Goal/Outcome/Key decisions/Learnings/Links.
  local in_entry=0
  local entry_date="" title="" goal="" outcome="" key_decisions="" learnings="" links=""
  local session_id=""

  flush_entry() {
    [[ -z "$title" && -z "$entry_date" ]] && return
    [[ -z "$session_id" ]] && session_id=$(make_session_id "${entry_date}-${title}")

    local payload
    payload=$(jq -n \
      --arg sid  "$session_id" \
      --arg host "$hostname" \
      --arg date "$entry_date" \
      --arg ttl  "$title" \
      --arg g    "$goal" \
      --arg o    "$outcome" \
      --arg kd   "$key_decisions" \
      --arg l    "$learnings" \
      --arg lk   "$links" \
      '{session_id:$sid, hostname:$host, type:"session_log",
        entry_date:$date, title:$ttl, goal:$g, outcome:$o,
        key_decisions:$kd, learnings:$l, links:$lk}')

    if ingest_payload "$payload"; then
      count=$((count + 1))
    fi

    # Reset state
    entry_date=""; title=""; goal=""; outcome=""
    key_decisions=""; learnings=""; links=""; session_id=""
    in_entry=0
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Detect heading: ## YYYY-MM-DD — Title  (em-dash or double-hyphen)
    if [[ "$line" =~ ^##[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+[—–-]+[[:space:]]*(.+)$ ]]; then
      # Flush any previous entry before starting a new one
      flush_entry
      entry_date="${BASH_REMATCH[1]}"
      title="${BASH_REMATCH[2]}"
      in_entry=1
      continue
    fi

    # Detect inline session annotation (optional): session: abc123
    if [[ "$in_entry" -eq 1 && "$line" =~ session:[[:space:]]*([a-zA-Z0-9_-]+) ]]; then
      session_id="${BASH_REMATCH[1]}"
    fi

    # Detect sub-fields (bullet or plain bold lines)
    if [[ "$in_entry" -eq 1 ]]; then
      local stripped
      stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')

      if [[ "$stripped" =~ ^\*\*Goal\*\*:[[:space:]]*(.+)$ ]]; then
        goal="${BASH_REMATCH[1]}"
      elif [[ "$stripped" =~ ^\*\*Outcome\*\*:[[:space:]]*(.+)$ ]]; then
        outcome="${BASH_REMATCH[1]}"
      elif [[ "$stripped" =~ ^\*\*Key[[:space:]]decisions?\*\*:[[:space:]]*(.+)$ ]]; then
        key_decisions="${BASH_REMATCH[1]}"
      elif [[ "$stripped" =~ ^\*\*Learnings?\*\*:[[:space:]]*(.+)$ ]]; then
        learnings="${BASH_REMATCH[1]}"
      elif [[ "$stripped" =~ ^\*\*Links?\*\*:[[:space:]]*(.+)$ ]]; then
        links="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$filepath"

  # Flush last entry
  flush_entry

  info "  imported $count session log entries from $(basename "$filepath")"
  return 0
}

# ---- Parse and ingest Technical Learnings.md ----
ingest_tech_learnings_file() {
  local filepath="$1"
  local count=0

  [[ -f "$filepath" ]] || return 0

  info "parsing technical learnings: $filepath"

  local in_entry=0
  local number="" title="" problem="" solution="" applies_to=""
  local session_id="migrated-techlearn"

  flush_tl() {
    [[ -z "$title" ]] && return
    local sid
    sid=$(make_session_id "techlearn-${number}-${title}")

    local payload
    payload=$(jq -n \
      --arg sid   "$sid" \
      --arg num   "$number" \
      --arg ttl   "$title" \
      --arg prob  "$problem" \
      --arg sol   "$solution" \
      --arg app   "$applies_to" \
      '{session_id:$sid, type:"technical_learning",
        number:($num | if . == "" then null else (tonumber? // null) end),
        title:$ttl, problem:$prob, solution:$sol, applies_to:$app}')

    if ingest_payload "$payload"; then
      count=$((count + 1))
    fi

    number=""; title=""; problem=""; solution=""; applies_to=""
    in_entry=0
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Detect heading: ## N. Title  or  ## Title
    if [[ "$line" =~ ^##[[:space:]]+([0-9]+)\.[[:space:]]+(.+)$ ]]; then
      flush_tl
      number="${BASH_REMATCH[1]}"
      title="${BASH_REMATCH[2]}"
      in_entry=1
      continue
    elif [[ "$line" =~ ^##[[:space:]]+(.+)$ ]]; then
      # Could be a non-numbered heading (skip if it looks like a file header)
      local candidate="${BASH_REMATCH[1]}"
      # Skip headings that look like file titles (no sub-content yet, very short)
      if [[ "$in_entry" -eq 1 || "$candidate" =~ [Tt]echnical[[:space:]][Ll]earning ]]; then
        flush_tl
        if [[ ! "$candidate" =~ [Tt]echnical[[:space:]][Ll]earning ]]; then
          title="$candidate"
          number=""
          in_entry=1
        fi
        continue
      fi
    fi

    if [[ "$in_entry" -eq 1 ]]; then
      local stripped
      stripped=$(printf '%s' "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')

      if [[ "$stripped" =~ ^\*\*Problem\*\*:[[:space:]]*(.+)$ ]]; then
        problem="${BASH_REMATCH[1]}"
      elif [[ "$stripped" =~ ^\*\*Solution\*\*:[[:space:]]*(.+)$ ]]; then
        solution="${BASH_REMATCH[1]}"
      elif [[ "$stripped" =~ ^\*\*Applies[[:space:]]to\*\*:[[:space:]]*(.+)$ ]]; then
        applies_to="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$filepath"

  flush_tl

  info "  imported $count technical learning entries from $(basename "$filepath")"
  return 0
}

# ---- Rename source file to .pre-sqlite-backup ----
backup_file() {
  local src="$1"
  local dst="${src}.pre-sqlite-backup"
  if [[ -f "$dst" ]]; then
    warn "backup already exists, skipping rename: $dst"
    return 0
  fi
  if mv "$src" "$dst"; then
    info "  renamed: $(basename "$src") → $(basename "$dst")"
  else
    warn "  could not rename $src → $dst (continuing)"
  fi
}

# ---- Main ----
MIGRATED_ANY=0

# Per-device Session Log files: Session Log - <hostname>.md
shopt -s nullglob
SESSION_LOG_FILES=("$KNOWLEDGE_DIR"/Session\ Log\ -\ *.md)
shopt -u nullglob

# Also check canonical Session Log.md
CANONICAL_LOG="$KNOWLEDGE_DIR/Session Log.md"

ALL_SESSION_FILES=("${SESSION_LOG_FILES[@]}")
if [[ -f "$CANONICAL_LOG" ]]; then
  ALL_SESSION_FILES+=("$CANONICAL_LOG")
fi

if [[ ${#ALL_SESSION_FILES[@]} -eq 0 ]]; then
  warn "No Session Log files found in $KNOWLEDGE_DIR"
else
  for f in "${ALL_SESSION_FILES[@]}"; do
    # Infer hostname from filename
    local_host="unknown"
    base=$(basename "$f")
    if [[ "$base" =~ ^Session\ Log\ -\ (.+)\.md$ ]]; then
      local_host="${BASH_REMATCH[1]}"
    fi

    ingest_session_log_file "$f" "$local_host"
    backup_file "$f"
    MIGRATED_ANY=1
  done
fi

# Technical Learnings
TECH_FILE="$KNOWLEDGE_DIR/Technical Learnings.md"
if [[ -f "$TECH_FILE" ]]; then
  ingest_tech_learnings_file "$TECH_FILE"
  backup_file "$TECH_FILE"
  MIGRATED_ANY=1
else
  warn "Technical Learnings.md not found at $TECH_FILE (skipping)"
fi

if [[ "$MIGRATED_ANY" -eq 0 ]]; then
  info "Nothing to migrate."
  exit 2
fi

info "Migration complete. Run export-to-vault.sh --full-rebuild to regenerate markdown from DB."
exit 0
