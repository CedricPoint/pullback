# shellcheck shell=bash
#
# Keeping some and dropping the rest.
#
# Because every snapshot is a directory of hard links, deleting one frees only
# the blocks nothing else points at. Keeping a year of monthlies costs almost
# nothing, so the defaults are generous.

SNAPSHOT_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z$'

# Snapshots of one server, oldest first.
list_snapshots() {
  local root="$DEST/$1" entry name
  [ -d "$root" ] || return 0

  for entry in "$root"/*/; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")
    # An `if`, not a `&&`: with pipefail on, a loop whose last test is
    # false makes the whole pipeline fail, and the caller dies for nothing.
    if [[ "$name" =~ $SNAPSHOT_PATTERN ]]; then printf '%s\n' "$name"; fi
  done | sort

  return 0
}

# The half-finished ones a failed run left behind.
list_incomplete() {
  local root="$DEST/$1" entry name
  [ -d "$root" ] || return 0

  for entry in "$root"/.incomplete-*/; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")
    printf '%s\n' "$name"
  done

  return 0
}

# Deleting a directory is the one thing in here that cannot be undone, so it
# happens in exactly one place and only for a path that passes every check.
remove_snapshot() {
  # Two statements, not one: the arguments of a single `local` are expanded
  # before any of its variables exist, so a third assignment referring to the
  # first two would read whatever the caller happened to have lying around.
  local name="$1" snapshot="$2"
  local target="$DEST/$name/$snapshot"

  case "$snapshot" in
    .incomplete-*) : ;;
    *) [[ "$snapshot" =~ $SNAPSHOT_PATTERN ]] || { warn "refusing to delete \"$snapshot\": that is not a snapshot name"; return 1; } ;;
  esac

  [ -n "$DEST" ] && [ "$DEST" != "/" ] || { warn "refusing to delete anything: DEST looks wrong"; return 1; }
  [ -d "$target" ] || return 0
  [ -L "$target" ] && { warn "refusing to delete \"$snapshot\": it is a symlink"; return 1; }

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "    would delete $snapshot"
    return 0
  fi

  rm -rf -- "$target"
  log "    deleted $snapshot"
}

# Which snapshots to keep: the most recent dailies, then one per week, then
# one per month. The newest is always kept, whatever the numbers say.
plan_retention() {
  local name="$1"
  local snapshots keep=() seen_weeks=() seen_months=() index=0 stamp day week month

  mapfile -t snapshots < <(list_snapshots "$name" | sort -r)
  [ ${#snapshots[@]} -gt 0 ] || return 0

  for stamp in "${snapshots[@]}"; do
    day=${stamp%%T*}

    if [ "$index" -lt "$KEEP_DAILY" ]; then
      keep+=("$stamp")
      index=$((index + 1))
      continue
    fi

    week=$(date -u -d "$day" '+%G-%V' 2>/dev/null || printf '%s' "$day")
    month=${day%-*}

    if [ ${#seen_weeks[@]} -lt "$KEEP_WEEKLY" ] && ! contains "$week" ${seen_weeks+"${seen_weeks[@]}"}; then
      seen_weeks+=("$week")
      keep+=("$stamp")
      continue
    fi

    if [ ${#seen_months[@]} -lt "$KEEP_MONTHLY" ] && ! contains "$month" ${seen_months+"${seen_months[@]}"}; then
      seen_months+=("$month")
      keep+=("$stamp")
      continue
    fi
  done

  printf '%s\n' ${keep+"${keep[@]}"}
}

prune_server() {
  local name="$1" stamp
  local keep snapshots removed=0

  mapfile -t keep < <(plan_retention "$name")
  mapfile -t snapshots < <(list_snapshots "$name")
  [ ${#snapshots[@]} -gt 0 ] || return 0

  for stamp in "${snapshots[@]}"; do
    if contains "$stamp" ${keep+"${keep[@]}"}; then continue; fi
    remove_snapshot "$name" "$stamp" && removed=$((removed + 1))
  done

  # Wreckage from a run that failed more than a week ago has been looked at
  # by now, or never will be.
  local incomplete age now
  now=$(date '+%s')
  while IFS= read -r incomplete; do
    [ -n "$incomplete" ] || continue
    age=$(( (now - $(modified_at "$DEST/$name/$incomplete")) / 86400 ))
    if [ "$age" -ge "${KEEP_INCOMPLETE_DAYS:-7}" ]; then
      remove_snapshot "$name" "$incomplete"
    else
      warn "    $incomplete is still there from a failed run $age day(s) ago"
    fi
  done < <(list_incomplete "$name")

  if [ "$removed" -gt 0 ]; then log "    kept ${#keep[@]}, removed $removed"; fi
  return 0
}

contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

modified_at() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date '+%s'
}
