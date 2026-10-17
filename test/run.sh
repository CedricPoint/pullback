#!/usr/bin/env bash
#
# Every test file, each in its own shell.
#
#   ./test/run.sh            all of them
#   ./test/run.sh unit       just the ones whose name matches

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
filter="${1:-}"
failed=0
ran=0

for file in "$here"/*.test.sh; do
  name=$(basename "$file" .test.sh)
  [ -n "$filter" ] && case "$name" in *"$filter"*) : ;; *) continue ;; esac

  printf '\n\033[1m%s\033[0m\n' "$name"
  ran=$((ran + 1))
  bash "$file" || failed=$((failed + 1))
done

if [ "$ran" -eq 0 ]; then
  printf 'no test file matched "%s"\n' "$filter" >&2
  exit 2
fi

if [ "$failed" -ne 0 ]; then
  printf '\033[31m%s of %s files failed\033[0m\n\n' "$failed" "$ran"
  exit 1
fi

printf '\033[32mall %s files passed\033[0m\n\n' "$ran"
