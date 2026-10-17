#!/usr/bin/env bash
# The parts that can be checked without pulling anything: the configuration,
# the retention plan, and the guards around deleting things.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

trap destroy_world EXIT
make_world
write_config

start "a configuration that makes no sense is refused, clearly"
bad() {
  local body="$1"
  printf 'DEST=%s\n%s\n' "$STORE" "$body" >"$WORLD/bad.conf"
  "$PULLBACK" --config "$WORLD/bad.conf" status 2>&1
}

check "a server with no host"      contains_text "$(bad 'server web --path /tmp')" "has no --host"
check "a server with nothing to take" contains_text "$(bad 'server web --host a@b')" "has nothing to back up"
check "the same name twice"        contains_text "$(bad 'server web --host a@b --path /tmp
server web --host a@b --path /tmp')" "declared twice"
check "an option that does not exist" contains_text "$(bad 'server web --host a@b --wat 1')" "not an option"
check "a name with a slash in it"  contains_text "$(bad 'server a/b --host a@b --path /tmp')" "not a usable server name"
check "no server at all"           contains_text "$(bad '# nothing here')" "declares no server"
check "a count that is not a number" contains_text "$(bad 'KEEP_DAILY=lots
server web --host a@b --path /tmp')" "must be a whole number"
check "the exit code says configuration" exits 2 "$PULLBACK" --config "$WORLD/bad.conf" status
check "a config file that is not there" contains_text "$("$PULLBACK" --config "$WORLD/nope.conf" status 2>&1)" "no configuration"

start "DEST is checked before anything is written to it"
check "the root of the filesystem is refused" contains_text "$(printf 'DEST=/\nserver w --host a@b --path /tmp\n' >"$WORLD/d.conf"; "$PULLBACK" --config "$WORLD/d.conf" status 2>&1)" "must not be the root"
check "a relative path is refused"           contains_text "$(printf 'DEST=backups\nserver w --host a@b --path /tmp\n' >"$WORLD/d.conf"; "$PULLBACK" --config "$WORLD/d.conf" status 2>&1)" "must be an absolute path"

start "the retention plan keeps the right snapshots"
. "$ROOT/lib/log.sh"
. "$ROOT/lib/config.sh"
. "$ROOT/lib/retention.sh"

DEST="$WORLD/retention"
KEEP_DAILY=3
KEEP_WEEKLY=2
KEEP_MONTHLY=2
mkdir -p "$DEST/srv"

# Twenty days of snapshots, one a day.
for day in $(seq 0 19); do
  stamp=$(date -u -d "2026-06-20 -${day} days" '+%Y-%m-%dT030000Z' 2>/dev/null)
  mkdir -p "$DEST/srv/$stamp"
done

mapfile -t kept < <(plan_retention srv)
newest=$(list_snapshots srv | tail -1)
oldest=$(list_snapshots srv | head -1)

check "there are twenty to choose from" equal "$(list_snapshots srv | wc -l | tr -d ' ')" 20
check "the newest is always kept" bash -c "printf '%s\n' ${kept[*]} | grep -q '$newest'"
check "three dailies, then weeklies, then monthlies" equal "${#kept[@]}" 6
check "the oldest is dropped" bash -c "! printf '%s\n' ${kept[*]} | grep -q '$oldest'"

start "pruning deletes only what the plan dropped"
before=$(list_snapshots srv | wc -l | tr -d ' ')
DRY_RUN=1 prune_server srv >/dev/null 2>&1
check "a dry run deletes nothing" equal "$(list_snapshots srv | wc -l | tr -d ' ')" "$before"

prune_server srv >/dev/null 2>&1
after=$(list_snapshots srv | wc -l | tr -d ' ')
check "a real run keeps exactly the plan" equal "$after" "${#kept[@]}"
check "and the newest survived" test -d "$DEST/srv/$newest"

start "deleting is guarded"
mkdir -p "$DEST/srv/not-a-snapshot"
ln -sfn "$DEST/srv/$newest" "$DEST/srv/2020-01-01T000000Z"

check "a name that is not a snapshot is refused" exits 1 remove_snapshot srv not-a-snapshot
check "and is still there" test -d "$DEST/srv/not-a-snapshot"
check "a symlink is refused" exits 1 remove_snapshot srv 2020-01-01T000000Z
check "and is still there" test -L "$DEST/srv/2020-01-01T000000Z"

saved_dest="$DEST"
DEST=/
check "a DEST of / is refused" exits 1 remove_snapshot srv 2026-06-20T030000Z
DEST="$saved_dest"

start "names going to the far end are quoted"
. "$ROOT/lib/backup.sh"
check "a plain name" equal "$(quote shop)" "'shop'"
check "a quote in the name cannot break out" equal "$(quote "sh'op")" "'sh'\\''op'"
check "nor can a semicolon" equal "$(quote 'a; rm -rf /')" "'a; rm -rf /'"

start "sizes and ages read like English"
check "bytes"   equal "$(human 512)" "512 B"
check "kB"      equal "$(human 2048)" "2 kB"
check "MB"      equal "$(human 5242880)" "5 MB"
check "GB"      equal "$(human 3221225472)" "3 GB"
check "minutes" equal "$(human_age 300)" "5m"
check "hours"   equal "$(human_age 7800)" "2h 10m"
check "days"    equal "$(human_age 180000)" "2d 2h"

start "the command line behaves"
check "--help works"           exits 0 "$PULLBACK" --help
check "--version prints one"   contains_text "$("$PULLBACK" --version)" "0."
check "no command is a usage error" exits 2 "$PULLBACK" --config "$WORLD/pullback.conf"
check "an unknown command too"      exits 2 "$PULLBACK" --config "$WORLD/pullback.conf" frobnicate
check "an unknown option too"       exits 2 "$PULLBACK" --config "$WORLD/pullback.conf" --frobnicate run
check "an unknown server too"       exits 2 "$PULLBACK" --config "$WORLD/pullback.conf" run nosuchserver

finish
