# shellcheck shell=bash
#
# Getting it back.
#
# The part most backup scripts never grow, and the only part anybody actually
# cares about. It copies out of a snapshot into a directory you name, and it
# never writes over a live service: loading a dump back into a running
# database is a decision, so this prints the command and lets you make it.

command_restore() {
  local name="${1:-}" snapshot="" into="" want_path="" want_database="" force=0
  shift || true

  [ -n "$name" ] || die "which server? pullback restore <server> --into <directory>"

  while [ $# -gt 0 ]; do
    case "$1" in
      --snapshot) snapshot="${2:?--snapshot needs a value}"; shift 2 ;;
      --into)     into="${2:?--into needs a directory}"; shift 2 ;;
      --path)     want_path="${2:?--path needs a value}"; shift 2 ;;
      --database) want_database="${2:?--database needs a name}"; shift 2 ;;
      --force)    force=1; shift ;;
      *) die "restore: \"$1\" is not an option I know" ;;
    esac
  done

  contains "$name" "${SERVER_NAMES[@]}" || die "no server called \"$name\" in the configuration"
  [ -n "$into" ] || die "--into <directory> is required: this never restores in place"

  if [ -z "$snapshot" ]; then
    [ -L "$DEST/$name/latest" ] || die "$name has no snapshot yet"
    snapshot=$(basename "$(resolve_link "$DEST/$name/latest")")
  fi

  local source="$DEST/$name/$snapshot"
  [ -d "$source" ] || die "$name has no snapshot called $snapshot — try: pullback list $name"

  if [ -e "$into" ] && [ -n "$(ls -A "$into" 2>/dev/null)" ] && [ "$force" != 1 ]; then
    die "$into is not empty — point somewhere else, or pass --force if you mean it"
  fi
  mkdir -p "$into" || die "cannot create $into"

  step "$name / $snapshot  →  $into"

  if [ -n "$want_database" ]; then
    restore_database "$source" "$into" "$want_database"
    return $?
  fi

  if [ -n "$want_path" ]; then
    restore_files "$source" "$into" "$want_path"
    return $?
  fi

  restore_files "$source" "$into" ""
  if [ -d "$source/databases" ]; then restore_database "$source" "$into" ""; fi
  return 0
}

restore_files() {
  local source="$1" into="$2" want="$3"
  local from="$source/files"

  [ -d "$from" ] || { warn "this snapshot holds no files"; return 0; }

  if [ -n "$want" ]; then
    from="$source/files/${want#/}"
    [ -e "$from" ] || die "$want is not in this snapshot — pullback list $name --contents shows what is"
  fi

  # -a keeps owners, modes and times; the copy is what was on the server.
  cp -a -- "$from" "$into/" || return 1

  ok "$(count_files "$into") file(s), $(human "$(dir_size "$into")")"
}

restore_database() {
  local source="$1" into="$2" want="$3" dump count=0

  [ -d "$source/databases" ] || { warn "this snapshot holds no database dump"; return 0; }
  mkdir -p "$into/databases"

  for dump in "$source"/databases/*.dump.gz; do
    [ -f "$dump" ] || continue
    local base
    base=$(basename "$dump")
    if [ -n "$want" ] && [ "$base" != "$want" ] && [ "$base" != "$want.dump.gz" ]; then continue; fi

    cp -a -- "$dump" "$into/databases/" || return 1
    count=$((count + 1))
    ok "$base  $(human "$(file_size "$dump")")"
    print_load_command "$into/databases/$base"
  done

  [ "$count" -gt 0 ] || die "no dump in this snapshot matches \"$want\""
  return 0
}

# Printed, never run. Loading a dump is the one step that destroys something
# that currently works.
print_load_command() {
  local dump="$1" base
  base=$(basename "$dump")

  case "$base" in
    postgres-*)
      local database=${base#postgres-}
      database=${database%.dump.gz}
      log ""
      log "  ${C_DIM}to load it back, when you have decided to:${C_RESET}"
      log "  gunzip -c $dump | pg_restore --clean --if-exists -d $database"
      log ""
      ;;
    mysql-*)
      local database=${base#mysql-}
      database=${database%.dump.gz}
      log ""
      log "  ${C_DIM}to load it back, when you have decided to:${C_RESET}"
      log "  gunzip -c $dump | mysql $database"
      log ""
      ;;
  esac
}

# What is in the store, and optionally what is inside one snapshot.
command_list() {
  local names name snapshot contents=0 args=()

  for argument in "$@"; do
    case "$argument" in
      --contents) contents=1 ;;
      *) args+=("$argument") ;;
    esac
  done

  check_server_names ${args+"${args[@]}"}
  mapfile -t names < <(select_servers ${args+"${args[@]}"})

  for name in "${names[@]}"; do
    step "$name"
    local found=0

    while IFS= read -r snapshot; do
      [ -n "$snapshot" ] || continue
      found=1
      local dir="$DEST/$name/$snapshot" size marker=""
      size=$(dir_size "$dir")
      if [ "$(basename "$(resolve_link "$DEST/$name/latest" 2>/dev/null)")" = "$snapshot" ]; then marker="  ← latest"; fi
      printf '  %s  %9s%s\n' "$snapshot" "$(human "${size:-0}")" "$marker"

      if [ "$contents" = 1 ]; then
        sed 's/^/      /' "$dir/manifest.txt" 2>/dev/null
      fi
    done < <(list_snapshots "$name")

    [ "$found" = 1 ] || log "  nothing yet"
  done
}
