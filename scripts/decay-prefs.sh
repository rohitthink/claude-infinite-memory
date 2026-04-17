#!/bin/bash
# decay-prefs.sh — Monthly decay pass for User Profile.md
#
# Scans the four main preference sections (Communication style, Technical
# preferences, Anti-patterns, Tooling preferences) and moves any bullet
# whose last-reinforced date (or entry timestamp) is >180 days old into
# ## Archive (stale), preserving the text for recovery.
#
# Usage:
#   decay-prefs.sh [--dry-run] [--profile-path /path/to/User Profile.md]
#
# Cron example (1st of every month at 03:30):
#   30 3 1 * * /path/to/scripts/decay-prefs.sh >> ~/.claude/logs/decay.log 2>&1
#
# Exit codes:
#   0 — success (including no-op when nothing was stale)
#   1 — fatal error (missing file, bad args, write failed)
#
# HARDENING:
#   - dry-run flag prints what would happen without touching the file
#   - Stale entries are MOVED to Archive, never deleted (always recoverable)
#   - perl used for date arithmetic (macOS/Linux portable; avoids GNU date -d)
#   - Path containment check: profile must be inside VAULT or explicitly given

set -uo pipefail

# ---- Defaults ----
DRY_RUN=0
PROFILE_PATH=""
VAULT="${CLAUDE_BRIDGE_VAULT:-}"
STALE_DAYS=180
TODAY=$(date "+%Y-%m-%d")

# ---- Argument parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --profile-path)
      PROFILE_PATH="$2"
      shift 2
      ;;
    --stale-days)
      STALE_DAYS="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--dry-run] [--profile-path PATH] [--stale-days N]" >&2
      exit 1
      ;;
  esac
done

# ---- Resolve profile path ----
if [[ -z "$PROFILE_PATH" ]]; then
  if [[ -z "$VAULT" ]]; then
    echo "ERROR: CLAUDE_BRIDGE_VAULT not set and --profile-path not provided." >&2
    exit 1
  fi
  PROFILE_PATH="$VAULT/07 - Claude Knowledge/User Profile.md"
fi

if [[ ! -f "$PROFILE_PATH" ]]; then
  echo "ERROR: User Profile not found at: $PROFILE_PATH" >&2
  exit 1
fi

# ---- perl-based date math: returns days between two YYYY-MM-DD dates ----
days_since() {
  local past_date="$1"
  perl -MTime::Piece -e '
    my ($past, $today) = @ARGV;
    my $t_past  = eval { Time::Piece->strptime($past,  "%Y-%m-%d") } or do { print -1; exit };
    my $t_today = eval { Time::Piece->strptime($today, "%Y-%m-%d") } or do { print -1; exit };
    printf "%d\n", int(($t_today - $t_past) / 86400);
  ' "$past_date" "$TODAY"
}

# ---- Sections subject to decay (NOT Pending, NOT Archive) ----
DECAY_SECTIONS=(
  "Communication style"
  "Technical preferences"
  "Anti-patterns"
  "Tooling preferences"
)

# ---- Read file ----
CONTENT=$(<"$PROFILE_PATH")
ARCHIVED_COUNT=0
KEPT_COUNT=0

# ---- Work area: we'll build a new version of the file ----
# Strategy: process line-by-line, tracking which section we're in.
# Lines in a decay section that are bullet entries get a staleness check.
# Stale bullets are buffered and appended to ## Archive (stale) at the end.

NEW_LINES=()
ARCHIVE_ADDITIONS=()
IN_DECAY_SECTION=0
CURRENT_SECTION=""

while IFS= read -r line; do
  # Detect section headers
  if [[ "$line" =~ ^##[[:space:]]+(.*) ]]; then
    header="${BASH_REMATCH[1]}"
    IN_DECAY_SECTION=0
    CURRENT_SECTION="$header"
    for sec in "${DECAY_SECTIONS[@]}"; do
      if [[ "$header" == "$sec" ]]; then
        IN_DECAY_SECTION=1
        break
      fi
    done
    NEW_LINES+=("$line")
    continue
  fi

  # Skip non-bullet lines in decay sections (sub-headers, blank lines, prose)
  if [[ $IN_DECAY_SECTION -eq 0 ]]; then
    NEW_LINES+=("$line")
    continue
  fi

  # Only process bullet lines
  if [[ ! "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
    NEW_LINES+=("$line")
    continue
  fi

  # ---- Extract last-reinforced date from the bullet ----
  # Priority 1: explicit "last-reinforced: YYYY-MM-DD" annotation
  # Priority 2: leading timestamp "(promoted YYYY-MM-DD, ...)" or "(confirmed ... YYYY-MM-DD)"
  # Priority 3: no date found — treat as epoch-like (always stale guard: skip, don't demote)

  REF_DATE=""

  # Store patterns in variables — bash [[ =~ ]] misparsed complex bracket exprs inline
  re_reinforced='last-reinforced:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2})'
  re_promoted='promoted[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})'
  re_confirmed='confirmed[[:space:]].*([0-9]{4}-[0-9]{2}-[0-9]{2})'
  re_any_date='([0-9]{4}-[0-9]{2}-[0-9]{2})'

  # Try last-reinforced: YYYY-MM-DD (highest priority — most precise)
  if [[ "$line" =~ $re_reinforced ]]; then
    REF_DATE="${BASH_REMATCH[1]}"
  # Try promoted YYYY-MM-DD
  elif [[ "$line" =~ $re_promoted ]]; then
    REF_DATE="${BASH_REMATCH[1]}"
  # Try confirmed ... YYYY-MM-DD
  elif [[ "$line" =~ $re_confirmed ]]; then
    REF_DATE="${BASH_REMATCH[1]}"
  # Fallback: any bare YYYY-MM-DD in the line
  elif [[ "$line" =~ $re_any_date ]]; then
    REF_DATE="${BASH_REMATCH[1]}"
  fi

  # No date found: cannot assess staleness — keep as-is
  if [[ -z "$REF_DATE" ]]; then
    NEW_LINES+=("$line")
    continue
  fi

  # ---- Staleness check ----
  age=$(days_since "$REF_DATE")

  if [[ "$age" -lt 0 ]]; then
    # Date parse failed — keep entry
    NEW_LINES+=("$line")
    continue
  fi

  if [[ "$age" -le "$STALE_DAYS" ]]; then
    KEPT_COUNT=$(( KEPT_COUNT + 1 ))
    NEW_LINES+=("$line")
    continue
  fi

  # ---- Entry is stale: demote to Archive ----
  ARCHIVED_COUNT=$(( ARCHIVED_COUNT + 1 ))
  archive_line="${line} (archived ${TODAY}, was in: ${CURRENT_SECTION})"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY RUN] Would archive (age=${age}d): $line"
  else
    ARCHIVE_ADDITIONS+=("$archive_line")
  fi
  # Do NOT add to NEW_LINES — it's removed from the main section

done <<< "$CONTENT"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[DRY RUN] Summary: $ARCHIVED_COUNT entries would be archived, $KEPT_COUNT kept."
  exit 0
fi

if [[ $ARCHIVED_COUNT -eq 0 ]]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') decay-prefs: nothing stale (checked, kept=$KEPT_COUNT)"
  exit 0
fi

# ---- Inject Archive entries ----
# Find ## Archive (stale) section in NEW_LINES or append it.
ARCHIVE_HEADER_IDX=-1
for i in "${!NEW_LINES[@]}"; do
  if [[ "${NEW_LINES[$i]}" =~ ^##[[:space:]]+Archive[[:space:]]*\(stale\) ]]; then
    ARCHIVE_HEADER_IDX=$i
    break
  fi
done

if [[ $ARCHIVE_HEADER_IDX -eq -1 ]]; then
  # Section doesn't exist — append at end
  NEW_LINES+=("")
  NEW_LINES+=("## Archive (stale)")
  NEW_LINES+=("")
  ARCHIVE_HEADER_IDX=$(( ${#NEW_LINES[@]} - 1 ))
fi

# Insert archive entries right after the ## Archive (stale) header
# (find the insertion point: skip blank lines after header, then insert)
INSERT_AT=$(( ARCHIVE_HEADER_IDX + 1 ))
# Skip blank lines after header
while [[ $INSERT_AT -lt ${#NEW_LINES[@]} && -z "${NEW_LINES[$INSERT_AT]}" ]]; do
  INSERT_AT=$(( INSERT_AT + 1 ))
done

# Build final array with archive entries inserted
FINAL_LINES=()
for i in "${!NEW_LINES[@]}"; do
  if [[ $i -eq $INSERT_AT ]]; then
    for arc_line in "${ARCHIVE_ADDITIONS[@]}"; do
      FINAL_LINES+=("$arc_line")
    done
  fi
  FINAL_LINES+=("${NEW_LINES[$i]}")
done
# Edge case: INSERT_AT was at or past end of array
if [[ $INSERT_AT -ge ${#NEW_LINES[@]} ]]; then
  for arc_line in "${ARCHIVE_ADDITIONS[@]}"; do
    FINAL_LINES+=("$arc_line")
  done
fi

# ---- Write back ----
printf '%s\n' "${FINAL_LINES[@]}" > "$PROFILE_PATH"

echo "$(date '+%Y-%m-%d %H:%M:%S') decay-prefs: archived=$ARCHIVED_COUNT kept=$KEPT_COUNT profile=$PROFILE_PATH"
