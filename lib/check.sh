# shellcheck shell=bash
#
# Answering the only two questions that matter between now and the day you
# need the backup: is it still running, and is what it took still readable.

# One line per server, and a non-zero exit if any of them is behind.
command_status() {
  local names stale=0 name root last age snapshots size latest

  check_server_names "$@"
  mapfile -t names < <(select_servers "$@")
  [ ${#names[@]} -gt 0 ] || die "no server selected"

  printf '%-20s %-12s %-10s %-9s %s\n' SERVER LAST SNAPSHOTS SIZE STATE
  for name in "${names[@]}"; do
    root="$DEST/$name"
    last=0
    [ -f "$root/last-success" ] && last=$(cat "$root/last-success" 2>/dev/null || echo 0)
    snapshots=$(list_snapshots "$name" | wc -l | tr -d ' ')
    size=$(dir_size "$root")
    latest=""
    if [ -L "$root/latest" ]; then latest=$(basename "$(resolve_link "$root/latest")"); fi

    local state age_text
    if [ "$last" = 0 ]; then
      state="${C_RED}never run${C_RESET}"
      age_text="-"
      stale=1
    else
      age=$(( $(date '+%s') - last ))
      age_text=$(human_age "$age")
      if [ "$age" -gt $((MAX_AGE_HOURS * 3600)) ]; then
        state="${C_RED}stale${C_RESET}"
        stale=1
      else
        state="${C_GREEN}ok${C_RESET}"
      fi
    fi

    local pending
    pending=$(list_incomplete "$name" | wc -l | tr -d ' ')
    if [ "$pending" -gt 0 ]; then state="$state ${C_YELLOW}($pending unfinished)${C_RESET}"; fi

    printf '%-20s %-12s %-10s %-9s %b\n' "$name" "$age_text" "$snapshots" "$(human "${size:-0}")" "$state"
    if [ -n "$latest" ] && [ "${VERBOSE:-0}" = 1 ]; then printf '  %s\n' "$latest"; fi
  done

  return "$stale"
}

# Re-check the checksums written when the snapshot was taken.
command_verify() {
  local names name snapshot failures=0

  check_server_names "$@"
  mapfile -t names < <(select_servers "$@")
  [ ${#names[@]} -gt 0 ] || die "no server selected"

  for name in "${names[@]}"; do
    local snapshots=()
    if [ "${VERIFY_ALL:-0}" = 1 ]; then
      mapfile -t snapshots < <(list_snapshots "$name")
    else
      if [ -L "$DEST/$name/latest" ]; then snapshots=("$(basename "$(resolve_link "$DEST/$name/latest")")"); fi
    fi

    if [ ${#snapshots[@]} -eq 0 ]; then
      warn "$name: nothing to verify yet"
      continue
    fi

    for snapshot in "${snapshots[@]}"; do
      verify_snapshot "$name" "$snapshot" || failures=$((failures + 1))
    done
  done

  [ "$failures" -eq 0 ] || return 1
  return 0
}

verify_snapshot() {
  local name="$1" snapshot="$2" dir="$DEST/$name/$snapshot"

  if [ ! -f "$dir/MANIFEST.sha256" ]; then
    fail "$name/$snapshot has no manifest — it was not finished by this tool"
    return 1
  fi

  local bad
  bad=$( cd "$dir" && sha256sum --check --quiet MANIFEST.sha256 2>&1 )
  local status=$?

  if [ "$status" -ne 0 ]; then
    fail "$name/$snapshot does not match its checksums"
    printf '%s\n' "$bad" | head -5 | sed 's/^/      /'
    return 1
  fi

  local counted recorded
  counted=$(count_files "$dir/files")
  recorded=$(awk '/^files  */ { print $2 }' "$dir/manifest.txt" 2>/dev/null)

  if [ -n "$recorded" ] && [ "$counted" != "$recorded" ]; then
    fail "$name/$snapshot holds $counted files, the manifest says $recorded"
    return 1
  fi

  ok "$name/$snapshot  $(wc -l <"$dir/MANIFEST.sha256" | tr -d ' ') checksums, $counted files"
  return 0
}

# Everything that should be true before the first run, checked now rather
# than at four in the morning.
command_doctor() {
  local names name problems=0

  step "here"
  for tool in rsync ssh sha256sum find du; do
    if command -v "$tool" >/dev/null 2>&1; then ok "  $tool"
    else fail "  $tool is missing"; problems=$((problems + 1)); fi
  done

  if [ -d "$DEST" ]; then
    if [ -w "$DEST" ]; then ok "  $DEST is writable"
    else fail "  $DEST is not writable by $(id -un)"; problems=$((problems + 1)); fi

    local free
    free=$(df -P "$DEST" | awk 'NR==2 { print $4 * 1024 }')
    log "  $(human "$free") free"
  else
    fail "  $DEST does not exist"
    problems=$((problems + 1))
  fi

  check_server_names "$@"
  mapfile -t names < <(select_servers "$@")

  for name in "${names[@]}"; do
    step "$name  (${SERVER_HOST[$name]})"

    if ! remote_run "$name" true >/dev/null 2>&1; then
      fail "  cannot reach it over ssh with BatchMode — is the key in place?"
      problems=$((problems + 1))
      continue
    fi
    ok "  ssh"

    local needed=("bash")
    if [ -n "${SERVER_PATHS[$name]}" ]; then needed+=("rsync"); fi
    if [ -n "${SERVER_POSTGRES[$name]}" ]; then needed+=("pg_dump" "gzip"); fi
    if [ -n "${SERVER_MYSQL[$name]}" ]; then needed+=("mysqldump" "gzip"); fi

    local missing
    missing=$(remote_run "$name" "for t in ${needed[*]}; do command -v \$t >/dev/null || echo \$t; done" 2>/dev/null)
    if [ -n "$missing" ]; then
      fail "  missing over there: $(printf '%s' "$missing" | tr '\n' ' ')"
      problems=$((problems + 1))
    else
      ok "  ${needed[*]}"
    fi

    local path
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if remote_run "$name" "test -r $(quote "$path")" >/dev/null 2>&1; then ok "  $path"
      else fail "  $path is not readable by $(printf '%s' "${SERVER_HOST[$name]}" | cut -d@ -f1)"; problems=$((problems + 1)); fi
    done < <(each_line "${SERVER_PATHS[$name]}")
  done

  printf '\n'
  if [ "$problems" -eq 0 ]; then
    ok "nothing to fix"
    log ""
    log "${C_DIM}For a stricter setup, give the backup key its own line over there:${C_RESET}"
    log "${C_DIM}  command=\"rrsync -ro /\",restrict ssh-ed25519 AAAA… pullback${C_RESET}"
    log "${C_DIM}That key can then read, and only read.${C_RESET}"
    return 0
  fi

  fail "$problems thing(s) to fix before this can work"
  return 1
}
