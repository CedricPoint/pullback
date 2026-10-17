# shellcheck shell=bash
#
# The configuration file, which is a small shell DSL: a few settings and one
# `server` call per machine. Sourcing it means the file can do anything the
# tool can, which is why the installer makes it root-owned and 0600 — the same
# deal as /etc/default anywhere else.

# Defaults. Everything here can be overridden by the config file.
DEST="${DEST:-/srv/backups}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"
MIN_DUMP_BYTES="${MIN_DUMP_BYTES:-512}"
SSH_OPTIONS="${SSH_OPTIONS:--o BatchMode=yes -o ConnectTimeout=15}"
SSH_COMMAND="${SSH_COMMAND:-ssh}"
RSYNC_COMMAND="${RSYNC_COMMAND:-rsync}"
PG_DUMP_COMMAND="${PG_DUMP_COMMAND:-pg_dump --no-owner --format=custom}"
MYSQLDUMP_COMMAND="${MYSQLDUMP_COMMAND:-mysqldump --single-transaction --quick}"
NOTIFY_COMMAND="${NOTIFY_COMMAND:-}"
LOG_FILE="${LOG_FILE:-}"

SERVER_NAMES=()
declare -A SERVER_HOST SERVER_PATHS SERVER_POSTGRES SERVER_MYSQL SERVER_EXCLUDE SERVER_SSH

# The one function a configuration file calls.
#
#   server prod-web --host root@example.com --path /var/www --postgres app
#
server() {
  local name="${1:-}"
  shift || true

  [ -n "$name" ] || die "a server needs a name: server <name> --host user@machine …"
  case "$name" in
    *[!A-Za-z0-9._-]*) die "\"$name\" is not a usable server name: letters, digits, dot, dash, underscore" ;;
  esac
  for existing in ${SERVER_NAMES+"${SERVER_NAMES[@]}"}; do
    [ "$existing" = "$name" ] && die "\"$name\" is declared twice"
  done

  SERVER_NAMES+=("$name")
  SERVER_HOST["$name"]=""
  SERVER_PATHS["$name"]=""
  SERVER_POSTGRES["$name"]=""
  SERVER_MYSQL["$name"]=""
  SERVER_EXCLUDE["$name"]=""
  SERVER_SSH["$name"]=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --host)     SERVER_HOST["$name"]="${2:?--host needs a value}"; shift 2 ;;
      --path)     SERVER_PATHS["$name"]+="${2:?--path needs a value}"$'\n'; shift 2 ;;
      --postgres) SERVER_POSTGRES["$name"]+="${2:?--postgres needs a database}"$'\n'; shift 2 ;;
      --mysql)    SERVER_MYSQL["$name"]+="${2:?--mysql needs a database}"$'\n'; shift 2 ;;
      --exclude)  SERVER_EXCLUDE["$name"]+="${2:?--exclude needs a pattern}"$'\n'; shift 2 ;;
      --ssh)      SERVER_SSH["$name"]="${2:?--ssh needs options}"; shift 2 ;;
      *) die "server $name: \"$1\" is not an option I know" ;;
    esac
  done

  [ -n "${SERVER_HOST[$name]}" ] || die "server $name has no --host"

  if [ -z "${SERVER_PATHS[$name]}" ] && [ -z "${SERVER_POSTGRES[$name]}" ] && [ -z "${SERVER_MYSQL[$name]}" ]; then
    die "server $name has nothing to back up: add a --path, a --postgres or a --mysql"
  fi
}

load_config() {
  local file="$1"

  [ -f "$file" ] || die "no configuration at $file — run: pullback init"
  # shellcheck source=/dev/null
  . "$file"

  [ ${#SERVER_NAMES[@]} -gt 0 ] || die "$file declares no server"
  [ -n "$DEST" ] || die "DEST is empty: where should the backups go?"

  case "$DEST" in
    /) die "DEST must not be the root of the filesystem" ;;
    /*) : ;;
    *) die "DEST must be an absolute path, got \"$DEST\"" ;;
  esac

  for number in KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY MAX_AGE_HOURS MIN_DUMP_BYTES; do
    case "${!number}" in
      ''|*[!0-9]*) die "$number must be a whole number, got \"${!number}\"" ;;
    esac
  done

  if [ -n "$NOTIFY_COMMAND" ] && ! command -v "$NOTIFY_COMMAND" >/dev/null 2>&1 && [ ! -x "$NOTIFY_COMMAND" ]; then
    warn "NOTIFY_COMMAND \"$NOTIFY_COMMAND\" is not something I can run — failures will be silent"
  fi
}

# Die here, in the caller's own shell, before select_servers runs inside a
# process substitution — `exit` in there kills only the subshell, and the run
# would carry cheerfully on having backed up nothing at all.
check_server_names() {
  local wanted found name
  for wanted in "$@"; do
    found=0
    for name in "${SERVER_NAMES[@]}"; do
      [ "$name" = "$wanted" ] && found=1
    done
    [ "$found" = 1 ] || die "no server called \"$wanted\" in the configuration"
  done
  return 0
}

# The names asked for on the command line, or all of them.
select_servers() {
  if [ $# -eq 0 ]; then
    printf '%s\n' "${SERVER_NAMES[@]}"
    return 0
  fi

  local wanted found
  for wanted in "$@"; do
    found=0
    for name in "${SERVER_NAMES[@]}"; do
      [ "$name" = "$wanted" ] && { printf '%s\n' "$name"; found=1; }
    done
    [ "$found" = 1 ] || die "no server called \"$wanted\" in the configuration"
  done
}

# Multi-valued fields are stored newline separated; this reads one back.
each_line() {
  local blob="$1"
  [ -n "$blob" ] || return 0
  printf '%s' "$blob" | while IFS= read -r line; do
    if [ -n "$line" ]; then printf '%s\n' "$line"; fi
  done

  return 0
}
