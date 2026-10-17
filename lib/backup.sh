# shellcheck shell=bash
#
# Taking one snapshot of one server.
#
# Two rules shape everything here:
#
#   The snapshot is built in .incomplete-<stamp> and only renamed into place
#   once every single part succeeded. A run that dies halfway leaves the last
#   good snapshot exactly where it was, and leaves its own wreckage behind to
#   be looked at rather than quietly cleaning up after itself.
#
#   Nothing is ever deleted before that rename. Pruning happens afterwards, on
#   purpose, and never touches the snapshot that was just made.

# Run a command on the far end and stream its output back here.
remote_run() {
  local name="$1" command="$2"
  # shellcheck disable=SC2086
  $SSH_COMMAND $SSH_OPTIONS ${SERVER_SSH[$name]} "${SERVER_HOST[$name]}" "$command"
}

snapshot_stamp() { date -u '+%Y-%m-%dT%H%M%SZ'; }

# Pull the files of one server into $work/files, hard-linking everything that
# has not changed since the previous snapshot.
snapshot_files() {
  local name="$1" work="$2" previous="$3"
  local paths exclude_args=() link_args=() path status

  paths=$(each_line "${SERVER_PATHS[$name]}")
  [ -n "$paths" ] || return 0

  while IFS= read -r pattern; do
    if [ -n "$pattern" ]; then exclude_args+=(--exclude "$pattern"); fi
  done <<<"$(each_line "${SERVER_EXCLUDE[$name]}")"

  if [ -n "$previous" ] && [ -d "$previous/files" ]; then
    link_args=(--link-dest="$previous/files")
  fi

  mkdir -p "$work/files"

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    log "    $path"

    set +e
    # shellcheck disable=SC2086
    "$RSYNC_COMMAND" --archive --relative --numeric-ids --hard-links --delete-excluded \
      --human-readable --stats \
      "${exclude_args[@]}" "${link_args[@]}" \
      -e "$SSH_COMMAND $SSH_OPTIONS ${SERVER_SSH[$name]}" \
      "${SERVER_HOST[$name]}:$path" "$work/files/" >>"$work/rsync.log" 2>&1
    status=$?
    set -e

    case "$status" in
      0) : ;;
      # 24 means files disappeared between the listing and the copy, which is
      # what a live server does all day. It is a warning, not a failure — the
      # distinction that silently breaks most home-made backup scripts.
      24) warn "    some files vanished while copying $path (rsync 24) — carrying on" ;;
      *) fail "    rsync failed on $path (exit $status); see $work/rsync.log"; return 1 ;;
    esac
  done <<<"$paths"

  return 0
}

# Dump a database on the far end and stream it straight here, so the server
# being backed up never has to find room for a copy of itself.
snapshot_databases() {
  local name="$1" work="$2" kind command databases database target size

  for kind in postgres mysql; do
    if [ "$kind" = postgres ]; then
      databases=$(each_line "${SERVER_POSTGRES[$name]}")
      command="$PG_DUMP_COMMAND"
    else
      databases=$(each_line "${SERVER_MYSQL[$name]}")
      command="$MYSQLDUMP_COMMAND"
    fi
    [ -n "$databases" ] || continue

    mkdir -p "$work/databases"

    while IFS= read -r database; do
      [ -n "$database" ] || continue
      target="$work/databases/$kind-$database.dump.gz"
      log "    $kind: $database"

      # The pipeline runs on the far end, so its exit status is gzip's. Without
      # pipefail over there, pg_dump can die halfway, gzip can cheerfully
      # compress the truncated output, and ssh reports success — a dump that
      # looks fine until the day you need it.
      local script="set -o pipefail; $command $(quote "$database") | gzip -1"
      local status

      set +e
      remote_run "$name" "bash -c $(quote "$script")" >"$target" 2>>"$work/dump.log"
      status=$?
      set -e

      if [ "$status" -ne 0 ]; then
        fail "    $kind dump of $database failed (exit $status); see $work/dump.log"
        return 1
      fi

      size=$(file_size "$target")
      if [ "$size" -lt "$MIN_DUMP_BYTES" ]; then
        fail "    $kind dump of $database is only $(human "$size") — refusing to call that a backup"
        return 1
      fi

      log "      $(human "$size")"
    done <<<"$databases"
  done

  return 0
}

# A record of what was taken, and checksums for the things worth checking.
write_manifest() {
  local name="$1" work="$2" stamp="$3" started="$4"
  local files=0 bytes=0

  if [ -d "$work/files" ]; then
    files=$(count_files "$work/files")
    bytes=$(dir_size "$work/files")
  fi

  {
    printf 'server      %s\n' "$name"
    printf 'snapshot    %s\n' "$stamp"
    printf 'host        %s\n' "${SERVER_HOST[$name]}"
    printf 'started     %s\n' "$(date -u -d "@$started" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'finished    %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'files       %s\n' "$files"
    printf 'file bytes  %s\n' "${bytes:-0}"
    each_line "${SERVER_PATHS[$name]}"    | sed 's/^/path        /'
    each_line "${SERVER_POSTGRES[$name]}" | sed 's/^/postgres    /'
    each_line "${SERVER_MYSQL[$name]}"    | sed 's/^/mysql       /'
  } >"$work/manifest.txt"

  # Every database dump is checksummed, because that is the part that cannot
  # be reconstructed from anywhere else. Files get a sample, so verifying a
  # terabyte does not take all night — `pullback verify --full` does the lot.
  (
    cd "$work" || exit 1
    : >MANIFEST.sha256
    if [ -d databases ]; then
      find databases -type f -print0 | sort -z | xargs -0 -r sha256sum >>MANIFEST.sha256
    fi
    if [ -d files ]; then
      sample="${MANIFEST_SAMPLE:-50}"
      taken=0
      while IFS= read -r -d '' path; do
        sha256sum "$path" >>MANIFEST.sha256
        taken=$((taken + 1))
        if [ "$taken" -ge "$sample" ]; then break; fi
      done < <(find files -type f -print0 | sort -z)
    fi
  )
}

# The whole thing, for one server.
backup_server() {
  local name="$1"
  local root="$DEST/$name"
  local stamp started work previous

  stamp=$(snapshot_stamp)
  started=$(date '+%s')
  work="$root/.incomplete-$stamp"
  previous=""

  if [ -L "$root/latest" ]; then previous=$(resolve_link "$root/latest"); fi

  step "$name  →  $stamp"
  mkdir -p "$work" || { fail "$name: cannot create $work"; return 1; }

  if ! snapshot_files "$name" "$work" "$previous"; then
    warn "$name: left $work behind so you can see what happened"
    return 1
  fi

  if ! snapshot_databases "$name" "$work"; then
    warn "$name: left $work behind so you can see what happened"
    return 1
  fi

  write_manifest "$name" "$work" "$stamp" "$started"

  # Everything worked: this is the only line that makes the snapshot real.
  if ! mv "$work" "$root/$stamp"; then
    fail "$name: could not move the finished snapshot into place"
    return 1
  fi

  point_latest "$root" "$stamp"
  date '+%s' >"$root/last-success"

  ok "$name  $(human "$(dir_size "$root/$stamp")") in $(human_age $(( $(date '+%s') - started )))"

  return 0
}

point_latest() {
  local root="$1" stamp="$2"
  ln -sfn "$stamp" "$root/.latest.new" 2>/dev/null || return 0
  mv -T "$root/.latest.new" "$root/latest" 2>/dev/null || mv "$root/.latest.new" "$root/latest"
}

resolve_link() {
  local link="$1"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$link" 2>/dev/null || printf '%s' "$link"
  else
    printf '%s' "$link"
  fi
}

# du and find both exit non-zero over something they cannot read, after
# printing a perfectly good answer. With pipefail on, that failure would
# propagate and kill the run — so it is absorbed here, once.
dir_size() {
  local total=""
  total=$( { du -sb "$1" 2>/dev/null || true; } | cut -f1 )
  printf '%s' "${total:-0}"
}

count_files() {
  local total=""
  total=$( { find "$1" -type f 2>/dev/null || true; } | wc -l | tr -d ' ' )
  printf '%s' "${total:-0}"
}

file_size() {
  local path="$1"
  if [ ! -f "$path" ]; then printf '0'; return 0; fi
  stat -c %s "$path" 2>/dev/null || stat -f %z "$path" 2>/dev/null || wc -c <"$path" | tr -d ' '
}

# Single quotes for the far end, so a database called `; rm -rf /` is a
# database name and nothing else.
quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}
