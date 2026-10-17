# shellcheck shell=bash
#
# Looking at a server and proposing what to take from it.
#
# Two things govern this file:
#
#   It only reads. The probe below runs `test`, `ls`, `du` and a couple of
#   "list the databases" queries. It writes nothing, installs nothing, and
#   changes nothing on the machine it is pointed at.
#
#   It proposes. The configuration is printed for you to read, and only
#   written once you say so. A tool that guesses what matters and then acts
#   on its guess is not helpful.

# What runs on the far end. One pass, no dependencies beyond a shell, and
# every command that might not exist is guarded.
discovery_probe() {
  cat <<'PROBE'
emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-0}" "${4:-}"; }

# Nobody wants discovery to sit on a four-terabyte directory for twenty
# minutes. A measurement that does not come back quickly is reported as
# unknown rather than waited for.
size_of() {
  local bytes=""
  if command -v timeout >/dev/null 2>&1; then
    bytes=$(timeout 8 du -sx --block-size=1 "$1" 2>/dev/null | cut -f1)
    [ -z "$bytes" ] && bytes=-1
  else
    bytes=$(du -sx --block-size=1 "$1" 2>/dev/null | cut -f1)
  fi
  printf '%s' "${bytes:-0}"
}

seen=" "
offer() {                       # offer <path> <why>
  [ -d "$1" ] || return 0
  case "$seen" in *" $1 "*) return 0 ;; esac
  seen="$seen$1 "
  emit path "$1" "$(size_of "$1")" "$2"
}

emit host "$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo server)" 0 \
  "$( (. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME") || uname -s )"

# ---- web roots, read out of the server configuration rather than guessed
for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf /etc/nginx/nginx.conf; do
  [ -f "$conf" ] || continue
  sed -n 's/^[[:space:]]*root[[:space:]]\{1,\}\([^;]*\);.*/\1/p' "$conf" 2>/dev/null
done | sort -u | while IFS= read -r root; do
  [ -n "$root" ] && offer "$root" "nginx root"
done

for conf in /etc/apache2/sites-enabled/* /etc/httpd/conf.d/*.conf; do
  [ -f "$conf" ] || continue
  sed -n 's/^[[:space:]]*DocumentRoot[[:space:]]\{1,\}"\{0,1\}\([^"[:space:]]*\).*/\1/p' "$conf" 2>/dev/null
done | sort -u | while IFS= read -r root; do
  [ -n "$root" ] && offer "$root" "apache DocumentRoot"
done

[ -f /etc/caddy/Caddyfile ] && sed -n 's/^[[:space:]]*root[[:space:]]*\*\{0,1\}[[:space:]]*\([^[:space:]]*\).*/\1/p' /etc/caddy/Caddyfile 2>/dev/null \
  | sort -u | while IFS= read -r root; do
      case "$root" in /*) offer "$root" "caddy root" ;; esac
    done

offer /var/www "web files"
offer /srv/www "web files"

# ---- the configuration of whatever is installed
for dir in /etc/nginx /etc/apache2 /etc/httpd /etc/caddy /etc/letsencrypt \
           /etc/systemd/system /etc/cron.d /var/spool/cron /etc/ssh; do
  offer "$dir" "configuration"
done

# ---- things people put their applications in
for parent in /srv /opt /home; do
  [ -d "$parent" ] || continue
  for dir in "$parent"/*; do
    [ -d "$dir" ] || continue
    case "$dir" in /home/*) [ -d "$dir/public_html" ] && offer "$dir/public_html" "user web files"; continue ;; esac
    offer "$dir" "application directory"
  done
done

# ---- databases, asked for by name, never by copying their files
if command -v psql >/dev/null 2>&1; then
  pg=$(psql -At -c 'select datname from pg_database where not datistemplate and datallowconn' 2>/dev/null)
  how="direct"
  if [ -z "$pg" ] && command -v sudo >/dev/null 2>&1; then
    pg=$(sudo -n -u postgres psql -At -c 'select datname from pg_database where not datistemplate and datallowconn' 2>/dev/null)
    how="sudo -n -u postgres"
  fi
  printf '%s\n' "$pg" | while IFS= read -r db; do
    [ -n "$db" ] && [ "$db" != postgres ] && emit postgres "$db" 0 "$how"
  done
fi

if command -v mysql >/dev/null 2>&1; then
  my=$(mysql -N -B -e 'show databases' 2>/dev/null)
  how="direct"
  if [ -z "$my" ] && command -v sudo >/dev/null 2>&1; then
    my=$(sudo -n mysql -N -B -e 'show databases' 2>/dev/null)
    how="sudo -n"
  fi
  printf '%s\n' "$my" | while IFS= read -r db; do
    case "$db" in ''|information_schema|performance_schema|mysql|sys) continue ;; esac
    emit mysql "$db" 0 "$how"
  done
fi

# ---- found on purpose, and deliberately not proposed
[ -d /var/lib/postgresql ] && emit skip /var/lib/postgresql "$(size_of /var/lib/postgresql)" \
  "live database files: copying these gives you a corrupt database, the dump above is the way"
[ -d /var/lib/mysql ] && emit skip /var/lib/mysql "$(size_of /var/lib/mysql)" \
  "live database files: copying these gives you a corrupt database, the dump above is the way"
[ -d /var/lib/docker ] && emit skip /var/lib/docker "$(size_of /var/lib/docker)" \
  "docker's own storage: back up the compose files and the volumes you care about instead"
[ -d /var/cache ] && emit skip /var/cache "$(size_of /var/cache)" "caches, rebuilt by whatever made them"
[ -d /var/log ] && emit skip /var/log "$(size_of /var/log)" "logs: add it yourself if you need them kept"

# ---- notes worth printing
if command -v docker >/dev/null 2>&1; then
  projects=$(docker ps --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | sort -u | grep -c . || true)
  [ "${projects:-0}" -gt 0 ] && emit note docker 0 "$projects compose project(s) running — their directories are proposed above if they are under /srv or /opt"
fi

df -P / 2>/dev/null | awk -v OFS='	' 'NR==2 { print "disk", $3 * 1024, $2 * 1024, "" }'
PROBE
}

# /var/www and /var/www/html both turning up means the same files would be
# pulled twice. Keep the parent and drop whatever lives inside it.
#
# Reads paths on stdin, writes the ones worth keeping.
drop_nested_paths() {
  local kept=() path candidate covered

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path=${path%/}
    [ -n "$path" ] || path=/

    covered=0
    for candidate in ${kept+"${kept[@]}"}; do
      case "$path/" in "$candidate/"*) covered=1; break ;; esac
    done

    [ "$covered" = 1 ] && continue
    kept+=("$path")
  done < <(sort -u)

  printf '%s
' ${kept+"${kept[@]}"}
}

# A size the probe could not measure in time comes back as -1, and reads as
# a question mark rather than as a nonsense number.
shown_size() {
  if [ "${1:-0}" -ge 0 ] 2>/dev/null; then human "$1"; else printf '?'; fi
}

# Run the probe on a host that is not in the configuration yet.
probe_host() {
  local host="$1" extra="$2"
  # shellcheck disable=SC2086
  $SSH_COMMAND $SSH_OPTIONS $extra "$host" "bash -c $(quote "$(discovery_probe)")" 2>/dev/null
}

# What the excludes should be, judged from what was found.
suggest_excludes() {
  local findings="$1" excludes=()

  case "$findings" in
    *"application directory"*|*"web"*) excludes+=("node_modules" "vendor" ".cache" "*.log") ;;
    *) excludes+=("*.log") ;;
  esac

  printf '%s\n' "${excludes[@]}"
}

command_discover() {
  local host="" name="" extra="" assume_yes=0 print_only=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --name)  name="${2:?--name needs a value}"; shift 2 ;;
      --ssh)   extra="${2:?--ssh needs options}"; shift 2 ;;
      --yes|-y) assume_yes=1; shift ;;
      --print) print_only=1; shift ;;
      -*) die "discover: \"$1\" is not an option I know" ;;
      *) [ -z "$host" ] || die "one host at a time"; host="$1"; shift ;;
    esac
  done

  [ -n "$host" ] || die "which machine? pullback discover user@host"

  step "looking at $host"
  log "  ${C_DIM}reading only: no file is written and nothing is installed over there${C_RESET}"

  local output
  output=$(probe_host "$host" "$extra") || true

  if [ -z "$output" ]; then
    die "$host did not answer, or has no bash. Try: $SSH_COMMAND $host true"
  fi

  render_discovery "$host" "$name" "$extra" "$output" "$assume_yes" "$print_only"
}

# Everything below is a pure function of the probe's output, which is what
# makes it testable without a server.
render_discovery() {
  local host="$1" name="$2" extra="$3" output="$4" assume_yes="$5" print_only="$6"
  local kind value bytes note
  local paths=() path_notes=() path_sizes=() postgres=() mysql=() pg_how="" my_how=""
  local total=0 hostname="" unmeasured=0

  while IFS=$'\t' read -r kind value bytes note; do
    case "$kind" in
      host) hostname="$value"; [ -n "$note" ] && log "  ${C_DIM}$note${C_RESET}" ;;
      path)
        paths+=("$value"); path_sizes+=("$bytes"); path_notes+=("$note")
        if [ "$bytes" -gt 0 ] 2>/dev/null; then total=$((total + bytes)); else unmeasured=1; fi
        ;;
      postgres) postgres+=("$value"); pg_how="$note" ;;
      mysql)    mysql+=("$value"); my_how="$note" ;;
      skip)
        printf '
'
        warn "  not proposing $value ($(shown_size "$bytes"))"
        log "    ${C_DIM}$note${C_RESET}"
        ;;
      disk)
        log "  ${C_DIM}the root filesystem holds $(human "$value") used of $(human "$bytes")${C_RESET}"
        ;;
      note)     log "  ${C_DIM}$note${C_RESET}" ;;
    esac
  done <<<"$output"

  [ -n "$name" ] || name=$(printf '%s' "${hostname:-server}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')

  # Shown as found, proposed without the overlaps.
  local proposed nested
  proposed=$(printf '%s\n' ${paths+"${paths[@]}"} | drop_nested_paths)
  nested=$(( ${#paths[@]} - $(printf '%s\n' "$proposed" | grep -c . || true) ))

  printf '\n'
  if [ ${#paths[@]} -eq 0 ] && [ ${#postgres[@]} -eq 0 ] && [ ${#mysql[@]} -eq 0 ]; then
    warn "found nothing worth proposing on $host"
    log "  ${C_DIM}add the paths by hand — pullback is not clever enough to guess an unusual layout${C_RESET}"
    return 1
  fi

  step "found on $host"
  local index=0
  for index in "${!paths[@]}"; do
    printf '  %-34s %9s  %s\n' "${paths[$index]}" "$(human "${path_sizes[$index]}")" "${C_DIM}${path_notes[$index]}${C_RESET}"
  done
  for db in ${postgres+"${postgres[@]}"}; do
    printf '  %-34s %9s  %s\n' "postgres: $db" "" "${C_DIM}dumped, ${pg_how}${C_RESET}"
  done
  for db in ${mysql+"${mysql[@]}"}; do
    printf '  %-34s %9s  %s\n' "mysql: $db" "" "${C_DIM}dumped, ${my_how}${C_RESET}"
  done

  printf '\n'
  log "  ${C_BOLD}$(human "$total")${C_RESET} of files, plus ${C_BOLD}$((${#postgres[@]} + ${#mysql[@]}))${C_RESET} database(s)"
  if [ "$nested" -gt 0 ]; then
    log "  ${C_DIM}$nested of those sit inside another one, so they are not proposed separately${C_RESET}"
  fi
  if [ "$unmeasured" = 1 ]; then
    log "  ${C_DIM}a ? means the directory was too large to measure in the time allowed${C_RESET}"
  fi
  log "  ${C_DIM}the first run copies all of it; after that only what changed${C_RESET}"

  local block
  block=$(configuration_block "$name" "$host" "$extra" \
    "$proposed" \
    "$(printf '%s\n' ${postgres+"${postgres[@]}"})" \
    "$(printf '%s\n' ${mysql+"${mysql[@]}"})" \
    "$pg_how" "$my_how")

  printf '\n%s\n\n' "$block"

  if [ "$print_only" = 1 ]; then
    return 0
  fi

  if [ "$assume_yes" != 1 ]; then
    if [ ! -t 0 ]; then
      log "  ${C_DIM}not a terminal: nothing was written. Pass --yes to append it, or --print for the block alone.${C_RESET}"
      return 0
    fi

    printf '  Append this to %s? [y/N] ' "$CONFIG"
    local answer=""
    read -r answer || true
    case "$answer" in
      y|Y|yes|YES) : ;;
      *) log "  nothing written"; return 0 ;;
    esac
  fi

  append_configuration "$block"
}

# The `server` block, built from what was found. Takes its lists as
# newline-separated strings rather than by reference: easier to read,
# easier to test, and no dependency on namerefs.
configuration_block() {
  local name="$1" host="$2" extra="$3"
  local path_list="$4" postgres_list="$5" mysql_list="$6" pg_how="$7" my_how="$8"
  local lines=() item

  # One literal backslash, named once, so the continuations below stay
  # readable instead of turning into a wall of escapes.
  local bs='\'

  lines+=("server $name $bs")
  lines+=("  --host $host $bs")
  if [ -n "$extra" ]; then lines+=("  --ssh '$extra' $bs"); fi

  while IFS= read -r item; do
    if [ -n "$item" ]; then lines+=("  --path $item $bs"); fi
  done <<<"$path_list"

  while IFS= read -r item; do
    if [ -n "$item" ]; then lines+=("  --postgres $item $bs"); fi
  done <<<"$postgres_list"

  while IFS= read -r item; do
    if [ -n "$item" ]; then lines+=("  --mysql $item $bs"); fi
  done <<<"$mysql_list"

  while IFS= read -r item; do
    if [ -n "$item" ]; then lines+=("  --exclude '$item' $bs"); fi
  done <<<"$(suggest_excludes "$path_list")"

  # The last line of a continued command must not end in one.
  local last=$(( ${#lines[@]} - 1 ))
  lines[$last]=${lines[$last]% $bs}

  local header=""
  if [ "$pg_how" = "sudo -n -u postgres" ]; then
    header="# postgres needed sudo over there, so this is how to dump it:"
    header="$header
PG_DUMP_COMMAND=\"sudo -n -u postgres pg_dump --no-owner --format=custom\"
"
  fi
  if [ "$my_how" = "sudo -n" ]; then
    header="$header# mysql needed sudo over there:
MYSQLDUMP_COMMAND=\"sudo -n mysqldump --single-transaction --quick\"
"
  fi

  if [ -n "$header" ]; then printf '%s\n' "$header"; fi
  printf '%s\n' "${lines[@]}"
}
append_configuration() {
  local block="$1"

  if [ ! -f "$CONFIG" ]; then
    mkdir -p "$(dirname "$CONFIG")" || die "cannot create $(dirname "$CONFIG")"
    cp "$SHARE/pullback.conf.example" "$CONFIG" 2>/dev/null || : >"$CONFIG"
    chmod 600 "$CONFIG" 2>/dev/null || true
    warn "$CONFIG did not exist — started it from the example, which declares servers of its own"
  fi

  {
    printf '\n# added by pullback discover on %s\n' "$(date '+%Y-%m-%d')"
    printf '%s\n' "$block"
  } >>"$CONFIG" || die "cannot write $CONFIG"

  ok "appended to $CONFIG"
  log ""
  log "  Next:"
  log "    pullback doctor         checks it can reach all of that"
  log "    pullback run            takes the first snapshot"
}
