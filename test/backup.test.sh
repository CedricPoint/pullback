#!/usr/bin/env bash
# The whole thing, against a fake server: pull, link, fail, verify, restore.

. "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

trap destroy_world EXIT
make_world
write_config

start "a first run takes a snapshot of files and of a database"
output=$(pb run 2>&1); status=$?
stamp=$(snapshot_of web)

check "the run succeeds" equal "$status" 0
check "a snapshot is named after the time" test -n "$stamp"
check "the files are there" test -f "$STORE/web/$stamp/files$REMOTE/var/www/index.html"
check "so is the second path" test -f "$STORE/web/$stamp/files$REMOTE/etc/nginx.conf"
check "excluded files are not" test ! -f "$STORE/web/$stamp/files$REMOTE/var/www/debug.log"
check "nor are excluded directories" test ! -d "$STORE/web/$stamp/files$REMOTE/var/www/cache"
check "the database dump is there" test -s "$STORE/db/$(snapshot_of db)/databases/postgres-shop.dump.gz"
check "and it is really gzip" bash -c "gunzip -t '$STORE/db/$(snapshot_of db)/databases/postgres-shop.dump.gz'"
check "a manifest was written" test -f "$STORE/web/$stamp/manifest.txt"
check "with checksums" test -s "$STORE/web/$stamp/MANIFEST.sha256"
check "the success is recorded" test -s "$STORE/web/last-success"
check "nothing was left half-finished" equal "$(ls -A "$STORE/web" | grep -c incomplete || true)" 0

start "a second run hard-links what did not change"
printf 'changed\n' >"$REMOTE/var/www/style.css"
sleep 1
pb run >/dev/null 2>&1
second=$(snapshot_of web)

first_untouched=$(inode_of "$STORE/web/$stamp/files$REMOTE/var/www/index.html")
second_untouched=$(inode_of "$STORE/web/$second/files$REMOTE/var/www/index.html")
first_changed=$(inode_of "$STORE/web/$stamp/files$REMOTE/var/www/style.css")
second_changed=$(inode_of "$STORE/web/$second/files$REMOTE/var/www/style.css")

check "the second snapshot is a new one" bash -c "[ '$second' != '$stamp' ]"
check "an unchanged file is the same inode" equal "$second_untouched" "$first_untouched"
check "a changed file is a new one" bash -c "[ '$second_changed' != '$first_changed' ]"
check "and holds the new content" contains_text "$(cat "$STORE/web/$second/files$REMOTE/var/www/style.css")" changed
check "the old snapshot still holds the old content" contains_text "$(cat "$STORE/web/$stamp/files$REMOTE/var/www/style.css")" style

start "a dump that dies halfway is not accepted"
cat >"$WORLD/pg_dump" <<'BROKEN'
#!/usr/bin/env bash
# Prints a bit, then fails — the shape of a dump that runs out of disk.
printf -- '-- dump of everything\n'
printf 'INSERT INTO t VALUES (1);\n'
exit 1
BROKEN
chmod +x "$WORLD/pg_dump"
before=$(snapshot_of db)
output=$(pb run db 2>&1); status=$?

check "the run reports failure" equal "$status" 1
check "and says which dump" contains_text "$output" "dump of shop failed"
check "the good snapshot is still the latest" equal "$(snapshot_of db)" "$before"
check "the wreckage is kept to be looked at" bash -c "ls -d '$STORE'/db/.incomplete-* >/dev/null 2>&1"

start "an empty dump is not a backup either"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORLD/pg_dump"
chmod +x "$WORLD/pg_dump"
output=$(pb run db 2>&1); status=$?

check "it fails" equal "$status" 1
check "and says why" contains_text "$output" "refusing to call that a backup"

start "a path that cannot be read fails the server, not the whole store"
cat >"$WORLD/pg_dump" <<'DUMP'
#!/usr/bin/env bash
printf -- '-- dump\n'
for i in $(seq 1 200); do printf 'INSERT INTO t VALUES (%s);\n' "$i"; done
DUMP
chmod +x "$WORLD/pg_dump"
write_config "
server broken \\
  --host nobody@example.invalid \\
  --path $WORLD/not-here
"
output=$(pb run 2>&1); status=$?

check "the run as a whole fails" equal "$status" 1
check "the broken one is named" contains_text "$output" "broken"
check "the healthy ones still ran" test -n "$(snapshot_of web)"
check "and the database one too" test -n "$(snapshot_of db)"

start "verify re-checks what was written"
write_config
pb run >/dev/null 2>&1
output=$(pb verify 2>&1); status=$?

check "a fresh snapshot verifies" equal "$status" 0
check "and says how much it checked" contains_text "$output" "checksums"

printf 'tampered\n' >>"$STORE/db/$(snapshot_of db)/databases/postgres-shop.dump.gz"
output=$(pb verify db 2>&1); status=$?

check "a tampered dump is caught" equal "$status" 1
check "and named" contains_text "$output" "does not match its checksums"

start "status knows when a server fell behind"
output=$(pb status 2>&1); status=$?
check "a fresh store is fine" equal "$status" 0
check "and is shown per server" contains_text "$output" "web"

printf '%s\n' "$(( $(date '+%s') - 400000 ))" >"$STORE/web/last-success"
output=$(pb status 2>&1); status=$?
check "an old one is not" equal "$status" 1
check "and is called stale" contains_text "$output" "stale"

start "restore puts things back where you ask, and only there"
target="$WORLD/restored"
output=$(pb restore web --into "$target" 2>&1); status=$?

check "it works" equal "$status" 0
check "the files are there" test -f "$target/files$REMOTE/var/www/index.html"
check "it refuses a directory that is not empty" exits 2 pb restore web --into "$target"
check "unless you insist" exits 0 pb restore web --into "$target" --force
check "it refuses without --into" exits 2 pb restore web
check "it refuses a snapshot that does not exist" exits 2 pb restore web --into "$WORLD/x" --snapshot 1999-01-01T000000Z

output=$(pb restore db --into "$WORLD/db-restore" --database postgres-shop 2>&1)
check "a database comes out as its dump" test -f "$WORLD/db-restore/databases/postgres-shop.dump.gz"
check "with the command to load it" contains_text "$output" "pg_restore"
check "which it does not run itself" lacks_text "$output" "loading"

start "list shows what is on disk"
output=$(pb list web 2>&1)
check "the snapshots are listed" contains_text "$output" "$(snapshot_of web)"
check "and the latest is marked" contains_text "$output" "latest"

finish
