#!/usr/bin/env bash
# ci-red-note-cron.sh — run do_report_ci_red_note (csi-spl-iac) every 10 min
# from the box user's crontab (spec 131 C2): ONE blocker to the dispatch lease
# holder per red wf 10 job on master, per red streak. Installed by
# do_install_box_crons as the manifest row ci-red-note
# (cnf/box-crons/box-crons.manifest), tagged `# csi-spl:box-cron:ci-red-note`.
# Every box runs it; only the holder's box sends the holder's blocker (the
# action checks), and every box tells the lanes it hosts when one of their
# commits is in a red job's suspect range (spec 133 action 7).
#
# A cron job reads no profile: the PATH is set here and the tools are checked
# before any work. gh with no login reads GH_TOKEN from CI_RED_NOTE_GH_TOKEN_FILE
# (default $HOME/.github/token, the box user's own) when that file exists.
#
#   ci-red-note-cron.sh [--check-tools]
#
# Exit: 0 ran (or another run held the lock), 1 the action failed, 2 usage or
# a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH
CI_RED_NOTE_TOOLS="${CI_RED_NOTE_TOOLS:-gh jq git flock}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $CI_RED_NOTE_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH)"
  return 3
}

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "ci-red-note-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
IAC="$(cd "$SELF/../../../../csi-spl-iac" && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the run needs resolves: $CI_RED_NOTE_TOOLS"; exit 0; fi
case "$IAC" in
  *-wt/*)
    [ "${CI_RED_NOTE_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $IAC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$IAC/run" ] || { say "FATAL $IAC/run not found or not executable"; exit 2; }
tf="${CI_RED_NOTE_GH_TOKEN_FILE:-$HOME/.github/token}"
if [ -z "${GH_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1 && [ -r "$tf" ]; then
  GH_TOKEN="$(cat "$tf")"; export GH_TOKEN
fi

lock="${CI_RED_NOTE_LOCK:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/ci-red-note.lock}"
mkdir -p "$(dirname "$lock")"
exec 9>"$lock"
flock -n 9 || { say "OK another ci-red-note run holds $lock"; exit 0; }
say "START ci-red-note"
( cd "$IAC" && ./run -a do_report_ci_red_note ); rc=$?
say "STOP ci-red-note rc=$rc"
[ "$rc" = 0 ] || exit 1
