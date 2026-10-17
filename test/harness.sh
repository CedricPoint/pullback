# shellcheck shell=bash
#
# A very small test harness, and a fake server to pull from.
#
# The fake server is the interesting part: PULLBACK's ssh command is
# configurable, so the tests point it at a shim that drops the host and runs
# the rest here. Real rsync, real hard links, real gzip, real checksums —
# only the network is missing.

set -uo pipefail

CHECKS=0
FAILURES=0
CURRENT=""

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PULLBACK="$ROOT/bin/pullback"

start() {
  CURRENT="$1"
  printf '  %s\n' "$CURRENT"
}

check() {
  local what="$1"; shift
  CHECKS=$((CHECKS + 1))

  if "$@"; then
    printf '    \033[32mok\033[0m    %s\n' "$what"
  else
    FAILURES=$((FAILURES + 1))
    printf '    \033[31mFAIL\033[0m  %s\n' "$what"
  fi
}

# check "…" equal "$got" "$want"
equal() {
  if [ "$1" = "$2" ]; then return 0; fi
  printf '          got:  %s\n          want: %s\n' "$1" "$2" >&2
  return 1
}

contains_text() {
  case "$1" in *"$2"*) return 0 ;; esac
  printf '          %s\n          does not contain: %s\n' "$(printf '%s' "$1" | head -3)" "$2" >&2
  return 1
}

lacks_text() {
  case "$1" in *"$2"*) printf '          unexpectedly contains: %s\n' "$2" >&2; return 1 ;; esac
  return 0
}

exits() {
  local wanted="$1"; shift
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  equal "$status" "$wanted"
}

finish() {
  printf '\n  %s checks, %s failed\n\n' "$CHECKS" "$FAILURES"
  [ "$FAILURES" -eq 0 ]
}

# ------------------------------------------------------------- the fake side

# A working directory with a pretend remote server in it.
make_world() {
  WORLD=$(mktemp -d)
  REMOTE="$WORLD/remote"
  STORE="$WORLD/store"

  mkdir -p "$REMOTE/var/www" "$REMOTE/etc" "$STORE"
  printf 'index\n' >"$REMOTE/var/www/index.html"
  printf 'style\n' >"$REMOTE/var/www/style.css"
  mkdir -p "$REMOTE/var/www/cache"
  printf 'junk\n' >"$REMOTE/var/www/cache/throwaway"
  printf 'noise\n' >"$REMOTE/var/www/debug.log"
  printf 'server {}\n' >"$REMOTE/etc/nginx.conf"

  cat >"$WORLD/ssh" <<'SHIM'
#!/usr/bin/env bash
# Pretend to be ssh: drop the options and the host, run the rest here.
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-i|-p|-J|-l) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift || true                      # the host
if [ $# -eq 1 ]; then exec bash -c "$1"; fi
exec "$@"
SHIM
  chmod +x "$WORLD/ssh"

  # A database that dumps something plausible.
  cat >"$WORLD/pg_dump" <<'DUMP'
#!/usr/bin/env bash
printf -- '-- dump of %s\n' "${!#}"
for i in $(seq 1 200); do printf 'INSERT INTO t VALUES (%s);\n' "$i"; done
DUMP
  chmod +x "$WORLD/pg_dump"
}

# A configuration pointing at the fake world.
write_config() {
  local extra="${1:-}"
  cat >"$WORLD/pullback.conf" <<CONF
DEST=$STORE
KEEP_DAILY=3
KEEP_WEEKLY=2
KEEP_MONTHLY=2
SSH_COMMAND=$WORLD/ssh
SSH_OPTIONS=
PG_DUMP_COMMAND=$WORLD/pg_dump
MIN_DUMP_BYTES=32
$extra

server web \\
  --host nobody@example.invalid \\
  --path $REMOTE/var/www \\
  --path $REMOTE/etc \\
  --exclude '*.log' \\
  --exclude 'cache/'

server db \\
  --host nobody@example.invalid \\
  --postgres shop
CONF
}

pb() {
  "$PULLBACK" --config "$WORLD/pullback.conf" "$@"
}

destroy_world() {
  [ -n "${WORLD:-}" ] && [ -d "$WORLD" ] && rm -rf "$WORLD"
  return 0
}

snapshot_of() {
  basename "$(readlink -f "$STORE/$1/latest" 2>/dev/null)" 2>/dev/null
}

inode_of() {
  stat -c %i "$1" 2>/dev/null
}
