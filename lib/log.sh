# shellcheck shell=bash
#
# Saying what happened, and making sure somebody hears about it when it went
# wrong. A backup that fails quietly is worse than no backup, because you
# stopped worrying about it.

PULLBACK_FAILED=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[90m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''
fi

_stamp() { date '+%Y-%m-%d %H:%M:%S'; }

_write() {
  local line="$1"
  printf '%s\n' "$line"
  [ -n "${LOG_FILE:-}" ] && printf '%s\n' "$line" >>"$LOG_FILE"
  return 0
}

log()   { _write "${C_DIM}$(_stamp)${C_RESET}  $*"; }
step()  { _write "${C_DIM}$(_stamp)${C_RESET}  ${C_BOLD}$*${C_RESET}"; }
ok()    { _write "${C_DIM}$(_stamp)${C_RESET}  ${C_GREEN}✓${C_RESET} $*"; }

warn() {
  _write "${C_DIM}$(_stamp)${C_RESET}  ${C_YELLOW}!${C_RESET} $*"
}

# A failure is recorded, announced, and remembered — the run carries on with
# the other servers, and the exit code at the end is non-zero.
fail() {
  PULLBACK_FAILED=$((PULLBACK_FAILED + 1))
  _write "${C_DIM}$(_stamp)${C_RESET}  ${C_RED}✗${C_RESET} $*"
  notify error "$*"
}

# Unrecoverable: the configuration or the environment is wrong.
die() {
  _write "${C_RED}pullback: $*${C_RESET}" >&2
  exit 2
}

# Hand a message to whatever the config wants to wake up. The hook is called
# with two arguments, level and message, so a one-line shell function can send
# it to Discord, e-mail, ntfy or a log collector.
notify() {
  local level="$1" message="$2"
  [ -n "${NOTIFY_COMMAND:-}" ] || return 0

  if ! "$NOTIFY_COMMAND" "$level" "$message" </dev/null >/dev/null 2>&1; then
    _write "${C_YELLOW}!${C_RESET} the notify command itself failed, which nobody will hear about"
  fi
  return 0
}

human() {
  local bytes="${1:-0}"
  if   [ "$bytes" -ge 1073741824 ]; then printf '%s GB' "$(( (bytes + 536870912) / 1073741824 ))"
  elif [ "$bytes" -ge 1048576 ];    then printf '%s MB' "$(( (bytes + 524288) / 1048576 ))"
  elif [ "$bytes" -ge 1024 ];       then printf '%s kB' "$(( (bytes + 512) / 1024 ))"
  else printf '%s B' "$bytes"; fi
}

human_age() {
  local seconds="${1:-0}"
  if   [ "$seconds" -ge 86400 ]; then printf '%sd %sh' "$((seconds / 86400))" "$(((seconds % 86400) / 3600))"
  elif [ "$seconds" -ge 3600 ];  then printf '%sh %sm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  else printf '%sm' "$((seconds / 60))"; fi
}
