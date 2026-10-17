#!/usr/bin/env bash
# Discovery: what it makes of what it found, without needing a server to look at.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

trap destroy_world EXIT
make_world
write_config

. "$ROOT/lib/log.sh"
. "$ROOT/lib/config.sh"
. "$ROOT/lib/backup.sh"
. "$ROOT/lib/discover.sh"

CONFIG="$WORLD/discovered.conf"
SHARE="$ROOT/share"

# What a probe comes back with, written out by hand so the test does not
# depend on whatever happens to be installed on the machine running it.
FOUND=$(printf '%s\n' \
  "host	web01	0	Debian GNU/Linux 12 (bookworm)" \
  "path	/var/www	2097152	nginx root" \
  "path	/etc/nginx	65536	configuration" \
  "path	/srv/app	-1	application directory" \
  "postgres	appdb	0	sudo -n -u postgres" \
  "mysql	legacy	0	direct" \
  "skip	/var/lib/postgresql	524288000	live database files: copying these gives you a corrupt database" \
  "note	disk	0	the root filesystem holds 8 GB used of 40 GB")

# Is <command> ever the first word of a command in this script? Comments are
# stripped first, so a probe that merely mentions installing something passes
# and one that calls it does not.
runs_command() {
  printf '%s
' "$1" | sed 's/#.*//' | awk -v wanted="$2" '
    {
      n = split($0, parts, /[;&|]/)
      for (i = 1; i <= n; i++) {
        line = parts[i]
        sub(/^[ 	]+/, "", line)
        split(line, word, /[ 	]+/)
        if (word[1] == wanted) found = 1
        if (word[1] == "sudo" && word[2] == wanted) found = 1
      }
    }
    END { exit(found ? 0 : 1) }'
}

never_runs() { ! runs_command "$1" "$2"; }
# Every redirection in the script, minus the ones to /dev/null and to
# another descriptor. Anything left over would be a file being written.
writes_a_file() {
  printf '%s
' "$1" | sed 's/#.*//'     | grep -oE '[0-9]*>>?[ 	]*[^ 	;&|)]+'     | grep -vE '>[ 	]*(/dev/|&)'     | grep -q .
}
never_writes() { ! writes_a_file "$1"; }

start "the remote probe is valid shell, and only reads"
probe=$(discovery_probe)

check "it parses as bash" bash -c 'printf "%s" "$1" | bash -n -' _ "$probe"
for dangerous in rm mkdir touch cp mv chmod chown install apt systemctl tee dd curl wget; do
  check "it never runs $dangerous" never_runs "$probe" "$dangerous"
done
check "and it writes to no file" never_writes "$probe"
check "it does measure sizes" contains_text "$probe" "du -sx"
check "it does list databases" contains_text "$probe" "pg_database"

start "a path inside another one is not proposed twice"
nested=$(printf '%s
' /var/www /var/www/html /var/www/document_errors/ /etc/nginx | drop_nested_paths)

check "the parent is kept" contains_text "$nested" "/var/www"
check "the child is dropped" lacks_text "$nested" "/var/www/html"
check "an unrelated path stays" contains_text "$nested" "/etc/nginx"
check "two left, not four" equal "$(printf '%s
' "$nested" | grep -c .)" 2

similar=$(printf '%s
' /var/www /var/www2 | drop_nested_paths)
check "a name that merely starts the same is not nested" equal "$(printf '%s
' "$similar" | grep -c .)" 2

trailing=$(printf '%s
' /srv/app/ /srv/app | drop_nested_paths)
check "a trailing slash is the same path" equal "$(printf '%s
' "$trailing" | grep -c .)" 1

start "the proposal reads back what was found"
output=$(render_discovery nobody@web01 "" "" "$FOUND" 0 1 2>&1)

check "the paths are listed" contains_text "$output" "/var/www"
check "with their size" contains_text "$output" "2 MB"
check "an unmeasured one shows a question mark" contains_text "$output" "?"
check "the databases are listed" contains_text "$output" "postgres: appdb"
check "and how they will be dumped" contains_text "$output" "sudo -n -u postgres"
check "the operating system is mentioned" contains_text "$output" "bookworm"

start "it says what it deliberately leaves out, and why"
check "the live database directory is refused" contains_text "$output" "not proposing /var/lib/postgresql"
check "with the reason" contains_text "$output" "corrupt database"
check "and it is not in the block" lacks_text "$output" "--path /var/lib/postgresql"

start "the block it proposes is a usable configuration"
block=$(configuration_block web01 nobody@web01 "" \
  "$(printf '/var/www\n/etc/nginx\n')" "$(printf 'appdb\n')" "$(printf 'legacy\n')" \
  "sudo -n -u postgres" "direct")

check "it declares the server" contains_text "$block" "server web01"
check "with the host" contains_text "$block" "--host nobody@web01"
check "the paths" contains_text "$block" "--path /var/www"
check "the databases" contains_text "$block" "--postgres appdb"
check "and the mysql one" contains_text "$block" "--mysql legacy"
check "excludes are suggested" contains_text "$block" "--exclude"
check "sudo is carried into the dump command" contains_text "$block" "PG_DUMP_COMMAND"
check "the last line does not dangle" bash -c "[ \"\$(printf '%s' \"\$1\" | tail -1 | grep -c '\\\\\\\\$')\" = 0 ]" _ "$block"

printf '%s\nDEST=%s\n%s\n' "# generated" "$STORE" "$block" >"$WORLD/generated.conf"
check "and the configuration it writes actually loads" exits 0 \
  "$PULLBACK" --config "$WORLD/generated.conf" list

start "nothing is written unless you say so"
rm -f "$CONFIG"
render_discovery nobody@web01 "" "" "$FOUND" 0 1 >/dev/null 2>&1
check "--print writes no file" test ! -f "$CONFIG"

render_discovery nobody@web01 "" "" "$FOUND" 1 0 >/dev/null 2>&1
check "--yes appends one" test -f "$CONFIG"
check "with the server in it" contains_text "$(cat "$CONFIG")" "server web01"
check "and a note saying where it came from" contains_text "$(cat "$CONFIG")" "pullback discover"

start "a probe that found nothing says so instead of proposing nothing"
empty=$(printf '%s\n' "host	bare	Alpine")
output=$(render_discovery nobody@bare "" "" "$empty" 1 0 2>&1); status=$?

check "it fails" equal "$status" 1
check "and says why" contains_text "$output" "found nothing worth proposing"

start "the command line behaves"
check "a host is required" exits 2 "$PULLBACK" --config "$WORLD/pullback.conf" discover
check "one host at a time" exits 2 "$PULLBACK" --config "$WORLD/pullback.conf" discover a@b c@d
check "an unknown option is refused" exits 2 "$PULLBACK" --config "$WORLD/pullback.conf" discover a@b --wat
check "a host that does not answer is a clear error" contains_text \
  "$("$PULLBACK" --config "$WORLD/pullback.conf" discover nobody@localhost.invalid 2>&1)" "did not answer"

finish
