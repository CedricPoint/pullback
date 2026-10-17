# pullback

**English** · [Français](README.fr.md)

**Back up whole servers onto a machine at home, by pulling.** One config file,
three commands, and a server that gets broken into cannot touch the copies of
itself — because it has no credentials for them and no route to them.

[![CI](https://github.com/CedricPoint/pullback/actions/workflows/ci.yml/badge.svg)](https://github.com/CedricPoint/pullback/actions/workflows/ci.yml)
[![bash](https://img.shields.io/badge/bash-4%2B-brightgreen.svg)](bin/pullback)
[![dependencies](https://img.shields.io/badge/dependencies-ssh%20%2B%20rsync-brightgreen.svg)](#what-it-needs)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

```console
$ pullback run

2026-10-17 03:30:02  pullback → /srv/backups
2026-10-17 03:30:02  web  →  2026-10-17T033002Z
2026-10-17 03:30:02      /var/www
2026-10-17 03:30:04      /etc/nginx
2026-10-17 03:30:11  ✓ web  2 GB in 0m
2026-10-17 03:30:11  app  →  2026-10-17T033011Z
2026-10-17 03:30:11      /srv/app
2026-10-17 03:30:14      postgres: appdb
2026-10-17 03:30:26        412 MB
2026-10-17 03:30:26  ✓ app  1 GB in 0m
2026-10-17 03:30:26  ✓ 2 server(s) in 15m

$ pullback status

SERVER               LAST         SNAPSHOTS  SIZE      STATE
web                  7h 20m       28         94 GB     ok
app                  7h 20m       28         31 GB     ok
```

## It can look at a server for you

```console
$ pullback discover root@198.51.100.10

looking at root@198.51.100.10
  reading only: no file is written and nothing is installed over there
  Ubuntu 24.04.4 LTS

!   not proposing /var/lib/postgresql (555 MB)
    live database files: copying these gives you a corrupt database, the dump above is the way

!   not proposing /var/lib/docker (?)
    docker's own storage: back up the compose files and the volumes you care about instead

found on root@198.51.100.10
  /var/www                               36 kB  web files
  /etc/nginx                            228 kB  configuration
  /etc/letsencrypt                       56 kB  configuration
  /srv/app                               16 GB  application directory
  postgres: appdb                               dumped, sudo -n -u postgres
  mysql: legacy                                 dumped, direct

  16 GB of files, plus 2 database(s)
  2 of those sit inside another one, so they are not proposed separately
  the first run copies all of it; after that only what changed

# postgres needed sudo over there, so this is how to dump it:
PG_DUMP_COMMAND="sudo -n -u postgres pg_dump --no-owner --format=custom"

server srv628772 \
  --host root@198.51.100.10 \
  --path /var/www \
  --path /etc/nginx \
  --path /etc/letsencrypt \
  --path /srv/app \
  --postgres appdb \
  --mysql legacy \
  --exclude 'node_modules' \
  --exclude 'vendor' \
  --exclude '.cache' \
  --exclude '*.log'

  Append this to /etc/pullback/pullback.conf? [y/N]
```

It reads the web roots out of the nginx, Apache and Caddy configuration
rather than guessing them, asks Postgres and MySQL what databases exist,
measures what each directory would cost, and folds `/var/www/html` into
`/var/www` instead of copying the same files twice. If a dump needed `sudo`
over there, the line that makes it work ends up in the block.

**It only reads.** The probe runs `test`, `ls`, `du`, `sed` over the
configuration files, and two "list the databases" queries. It writes nothing,
installs nothing, and a test in the suite fails if a command that could
change something ever appears in it.

**And it proposes.** The block is printed for you to read and edit; nothing is
written until you answer yes, or pass `--yes`. Piped into something that is
not a terminal, it prints and stops.

What it deliberately refuses is as useful as what it offers: live database
directories (copying those gives you a corrupt database — the dump is the way),
Docker's own storage, caches, and logs, each with the reason.

## Three commands to be running

```bash
git clone https://github.com/CedricPoint/pullback.git
cd pullback && sudo ./install.sh

pullback discover root@your-server       # proposes a configuration, writes it if you agree
pullback doctor                          # ssh, tools, paths — before you trust it
pullback run                             # the first snapshot
```

Then pick a schedule — the installer prints both lines:

```bash
cp /usr/local/lib/pullback/share/pullback.{service,timer} /etc/systemd/system/
systemctl enable --now pullback.timer
```

There is no `curl … | sh` here on purpose. Handing an unread script to a root
shell is a habit worth not spreading.

## The configuration, in full

```sh
DEST=/srv/backups

KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12

NOTIFY_COMMAND=/usr/local/bin/pullback-notify   # called: <level> <message>

server web \
  --host root@198.51.100.10 \
  --path /var/www \
  --path /etc/nginx \
  --exclude '*.log' \
  --exclude 'node_modules'

server app \
  --host deploy@198.51.100.11 \
  --path /srv/app \
  --postgres appdb \
  --mysql legacy
```

That is the whole thing. A machine reachable only through another one gets
`--ssh '-J jump@gateway'`; a dump that needs a different user gets a one-line
`PG_DUMP_COMMAND="sudo -n -u postgres pg_dump …"`.

## Why pulling

Push a backup and the production server holds a key to the backup store. Then
somebody gets in, and the first thing worth doing is deleting the backups —
which that key lets them do. Pulling inverts it: the backup machine holds the
key, reaches out, and nothing on the server knows where the copies live.

The hardening goes one step further, and `pullback doctor` prints the line:

```
command="rrsync -ro /",restrict ssh-ed25519 AAAA… pullback
```

With that in the server's `authorized_keys`, the backup key can read and only
read — even from the backup machine.

## What you get for the disk space

Every run makes a new snapshot directory, and every file that did not change
is a **hard link** to the one in the previous snapshot. Thirty days of history
costs thirty days of *changes*, not thirty copies. Deleting an old snapshot
frees only what nothing newer points at, which is why the defaults keep a
year of monthlies without anybody noticing.

```
/srv/backups/web/
    2026-10-17T033002Z/
        files/var/www/…
        files/etc/nginx/…
        databases/postgres-appdb.dump.gz
        manifest.txt
        MANIFEST.sha256
    latest -> 2026-10-17T033002Z
    last-success
```

Databases are dumped on the far end and **streamed straight here**, so the
machine being backed up never has to find room for a copy of itself.

## Failing loudly

This is the part most home-made backup scripts get wrong, and it is the part
that matters, because a backup you stopped thinking about is the one that is
not running.

- **A snapshot becomes real in one `mv`.** It is built in `.incomplete-…` and
  renamed only once every file and every dump succeeded. A run that dies
  halfway leaves the last good snapshot exactly where it was, and leaves its
  own wreckage behind to be looked at.
- **Nothing is deleted before that.** Pruning happens after a success, never
  before, and only for directory names that match a snapshot stamp exactly.
- **An empty dump is not a backup.** Anything under `MIN_DUMP_BYTES` fails the
  run instead of overwriting the good one.
- **`pipefail` on the far end too.** `pg_dump | gzip` over ssh returns gzip's
  exit code: the dump can die halfway, gzip compresses the truncated output,
  and ssh reports success. The dump command is wrapped so the failure comes
  back. This is the bug that produces a backup which looks fine until the day
  you need it.
- **rsync 24 is a warning, not a failure.** Files vanishing mid-copy is what a
  live server does all day. Every other exit code stops that server's run.
- **`pullback status` exits non-zero** as soon as a server is older than
  `MAX_AGE_HOURS`. Point your monitoring at that one line and a cron that
  quietly stopped firing becomes an alert instead of a surprise.
- **You are told when it recovers**, not only when it breaks.

## Getting it back

The part most backup scripts never grow.

```bash
pullback list web --contents                     # what is in there
pullback restore web --into /tmp/recover         # all of it
pullback restore web --into /tmp/recover --path /etc/nginx
pullback restore app --into /tmp/recover --database postgres-appdb
pullback verify --all                            # re-check every checksum
```

It never restores in place: `--into` is required, and it refuses a directory
that is not empty unless you say `--force`. For a database it copies the dump
out and **prints** the command to load it:

```
  to load it back, when you have decided to:
  gunzip -c /tmp/recover/databases/postgres-appdb.dump.gz | pg_restore --clean --if-exists -d appdb
```

Printed, not run. Loading a dump is the one step that destroys something that
currently works.

## What it needs

On the backup machine: `bash` 4+, `rsync`, `ssh`, `sha256sum`, and `flock` if
you want two cron runs not to overlap. On the servers: `bash`, `rsync`, and
`pg_dump` or `mysqldump` if you ask for databases. `pullback doctor` checks
all of it, on both sides, and tells you what is missing before four in the
morning does.

Nothing else. No agent, no daemon, no database, no language runtime.

## Tests

85 checks, against a fake server that is only fake in the network: real rsync,
real hard links, real gzip, real checksums, real permissions — the ssh command
is simply pointed at a shim that runs the far side locally.

```bash
./test/run.sh
```

They cover the things that are hard to get right and easy to believe you did:
that a second run really hard-links unchanged files and really does not link a
changed one, that a dump dying halfway fails the run, that a failed run leaves
the previous snapshot as `latest`, that pruning keeps exactly what the
retention plan says and that `--dry-run` deletes nothing, that deleting
refuses anything which is not a snapshot directory, and that a mistyped server
name is an error rather than a cheerful run that backed up nothing.

## License

MIT
