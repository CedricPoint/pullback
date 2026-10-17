# Contributing

The useful contribution here is a way this can fail quietly. That is the only
kind of bug that matters in a backup tool: one that lets you believe you have
a copy when you do not.

## Getting started

```bash
git clone https://github.com/CedricPoint/pullback.git
cd pullback
./test/run.sh                 # no install needed, and nothing is pulled over a network
./test/run.sh unit            # just the files whose name matches
bash bin/pullback --help
```

The tests need `bash` 4+, `rsync`, `gzip` and `sha256sum`. They run against a
fake server made of a directory and a shim pretending to be `ssh`, so
everything else about them is real: real rsync, real hard links, real
checksums, real permissions.

## How it fits together

| file | what it does |
| --- | --- |
| `bin/pullback` | arguments, the lock, the dispatch, exit codes |
| `lib/config.sh` | the configuration DSL, and refusing one that makes no sense |
| `lib/backup.sh` | one snapshot of one server: pull, dump, manifest, promote |
| `lib/retention.sh` | what to keep, and the guards around deleting |
| `lib/check.sh` | status, verify, doctor |
| `lib/restore.sh` | getting it back, and list |
| `lib/discover.sh` | looking at a server and proposing a configuration |
| `lib/log.sh` | output, and the notification hook |

## The rules this code lives by

Break one of these and the tool stops being trustworthy, so a pull request
that does will be turned down even if it is otherwise good:

1. **A snapshot becomes real in one `mv`**, after everything succeeded. Never
   write into the live snapshot directory.
2. **Nothing is deleted before a success**, and only `remove_snapshot` deletes
   anything — it checks the name, the symlink and `DEST` before `rm`.
3. **Every exit code is read**, including the far side of a pipe over ssh.
   `pg_dump | gzip` through ssh returns gzip's status unless something forces
   `pipefail` over there; it does, and it must keep doing so.
4. **An unexpected failure is loud.** Silence is reserved for success.
5. **The direction is pull.** Nothing in here should ever need a credential
   that lives on the machine being backed up.
6. **Discovery only reads, and only proposes.** The probe in
   `lib/discover.sh` must never run a command that changes anything, and the
   configuration it suggests is written only after a yes. A test fails if a
   writing command appears in the probe, so adding one is not an oversight
   you can make quietly.

## Shell style

- `set -euo pipefail` in the entry point, and code that survives it. Watch for
  `cond && action` as the last command in a loop or a function: with
  `pipefail` it makes the whole pipeline fail. Write `if … then … fi`.
- `local a="$1" b="$a/x"` does **not** work: the arguments of one `local` are
  expanded before any of its variables exist. Two statements.
- Quote everything. A path with a space in it is not an edge case.
- `shellcheck --severity=error` must pass; the warnings are printed by CI and
  worth reading.

## Adding a source of data

A new kind of thing to back up — a Redis dump, a Docker volume, a `--mongo`
flag — fits the same shape:

1. a `--something` option in `server()` in `lib/config.sh`;
2. a function in `lib/backup.sh` that streams it into `$work/`, checks its
   exit code and refuses a result that is too small to be real;
3. a check in `doctor` for whatever has to exist on the far end;
4. a test that the failure path leaves the previous snapshot alone.

Point four is the one that matters.
