#!/usr/bin/env bash
# lane-test-server-reap.sh - stop the e2e test servers a RETIRED lane left
# running, so its /tmp scratch can be removed. agent-id-retire.sh (step 8)
# runs it for the lane it retires, right before lane-scratch-reap.sh: a
# server holding the scratch made the reap KEEP it in-use, and so did every
# later sweep. Why (SPL-4762): on sat the retired c-810 (no window, no
# registry row) left `node src/node/test/serve-generated.mjs --root
# /tmp/claude-<uid>/<slug>/<session>/scratchpad/bundle-head --port 54435`
# running ~4 h as the agent user; its scratch held 57136 /tmp inodes. The
# agent had started it in the background by hand, so no harness trap stopped
# it (wui-e2e-mock-serve.sh and measure-wui-perf.mjs stop their own), and the
# orphan reaper (csi-spl-utl orphan-process-reap.func.sh) is report-only and
# reads AGENT_ID, which an agent's processes do not carry (SPOOL_AGENT_ID).
#
# A process is stopped only when ALL hold:
#   - its lane is proven retired: no tmux window carries the id, no
#     registry.tsv row names it, and registry.retired.tsv has its row
#     (agent-id-retire.sh wrote it; --retiring, a dry run only, skips the
#     two registry checks: the retire's own plan runs before it moves rows)
#   - its cwd, or an argument (or an --opt=value's value), is under the lane's
#     worktree or its Claude Code scratch (/tmp/claude-<uid>/<slug>[-*]/), or
#     under a private clone named for its id: /tmp/<id>[-*] or /var/tmp/<id>[-*]
#     (SPL-5065). Every such clone a server names must be proven retired, or
#     the server is kept (KEEP clone-not-retired)
#   - it is a known test server: an interpreter (node, python3, ...) running a
#     script whose name is in LANE_TEST_SERVER_SCRIPTS; never a name alone
#   - it runs as an agent user (LANE_TEST_SERVER_USERS)
# It gets SIGTERM, then SIGKILL after LANE_TEST_SERVER_GRACE_S, as its owner
# (sudo -n -u), and only while its start time is unchanged (no reused pid).
# One line per server (PLAN|DO stop / KEEP <why>), also appended to the log.
#
# Usage: lane-test-server-reap.sh [--apply] [--retiring] [--worktree <path>] <ID>
#        lane-test-server-reap.sh [--apply] --retired
#   without --apply: PLAN lines only, nothing signalled
#   --worktree  the lane's worktree (default: its last registry.retired.tsv
#               row's column 4); its last component must be the id
#   --retired   every id in registry.retired.tsv; a known test server under
#               no retired lane is named KEEP no-retired-lane
# Env: SPOOL_ROOT, SPOOL_TMUX_SOCKET, LANE_SCRATCH_TMP (default /tmp),
#   RETIRE_VARTMP_ROOT (default /var/tmp),
#   LANE_TEST_SERVER_USERS (default SPOOL_AGENT_USER and SPOOL_BOX_USER),
#   LANE_TEST_SERVER_SCRIPTS (default serve-generated.mjs serve-hosting-h2.mjs
#   wui-e2e-mock-api.py), LANE_TEST_SERVER_GRACE_S (default 5),
#   LANE_TEST_SERVER_SUDO=1|0 (0: only this user's processes; tests),
#   LANE_TEST_SERVER_LOG (default $XDG_STATE_HOME or ~/.local/state, then
#   <app>/lane-test-server-reap.log; "" = no log file)
#   LANE_TEST_SERVER_START_OVERRIDE (tests only: the start time compared, as
#   a reused pid would show it)
# A server whose cwd is under a LIVE lane's worktree is kept. A tmux window
# list or a registry that cannot be read refuses the run (exit 4).
# Exit 0 done (kept servers included); 2 usage or a worktree not named for
# its id; 3 a server did not stop; 4 refused, a read failed.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

APPLY=0 RETIRING=0 ALL=0 WT_ARG="" ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --retiring) RETIRING=1; shift ;;
    --retired) ALL=1; shift ;;
    --worktree) [ "$#" -ge 2 ] || { echo "lane-test-server-reap: --worktree needs a path" >&2; exit 2; }; WT_ARG="${2%/}"; shift 2 ;;
    -*) echo "lane-test-server-reap: unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$ID" ] || { echo "lane-test-server-reap: one id only" >&2; exit 2; }; ID="${1%%@*}"; shift ;;
  esac
done
[ "$ALL" = 1 ] && [ -n "$ID$WT_ARG" ] && { echo "lane-test-server-reap: --retired takes no id or --worktree" >&2; exit 2; }
[ "$ALL" = 1 ] || [ -n "$ID" ] || { echo "lane-test-server-reap: an id or --retired" >&2; exit 2; }
[ "$RETIRING$APPLY" != 11 ] || { echo "lane-test-server-reap: --retiring is for a dry run only" >&2; exit 2; }
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve
[ -z "$ID" ] || [[ "$ID" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || { echo "lane-test-server-reap: '${ID}' is not an agent id" >&2; exit 2; }

R="$SPOOL_ROOT"
_tmuxerr="$(mktemp)"; trap 'rm -f "$_tmuxerr"' EXIT
tmp="${LANE_SCRATCH_TMP:-/tmp}"
vartmp="${RETIRE_VARTMP_ROOT:-/var/tmp}"
users=" ${LANE_TEST_SERVER_USERS:-$SPOOL_AGENT_USER $SPOOL_BOX_USER} "
scripts=" ${LANE_TEST_SERVER_SCRIPTS:-serve-generated.mjs serve-hosting-h2.mjs wui-e2e-mock-api.py} "
grace="${LANE_TEST_SERVER_GRACE_S:-5}"
[[ "$grace" =~ ^[0-9]+$ ]] || { echo "lane-test-server-reap: LANE_TEST_SERVER_GRACE_S must be whole seconds, got '${grace}'" >&2; exit 2; }
use_sudo="${LANE_TEST_SERVER_SUDO:-1}"
me="$(id -un)"
orc="$(cd "$_here/../../../../.." && pwd)"
app="$(basename "$orc")"; app="${app%-orc}"
log="${LANE_TEST_SERVER_LOG-${XDG_STATE_HOME:-$HOME/.local/state}/$app/lane-test-server-reap.log}"

say() {
  local l; l="$(date -u +%Y-%m-%dT%H:%M:%SZ) lane-test-server-reap: $*"
  printf '%s\n' "$l"
  [ "$APPLY" = 1 ] && [ -n "$log" ] && { mkdir -p "${log%/*}" && printf '%s\n' "$l" >>"$log"; } 2>/dev/null
  return 0
}
# as_owner USER CMD...: CMD as USER (this user, root, or sudo -n -u USER)
as_owner() {
  local u="$1"; shift
  if [ "$u" = "$me" ] || [ "$(id -u)" = 0 ]; then "$@"
  elif [ "$use_sudo" = 1 ]; then sudo -n -u "$u" -- "$@"
  else return 1; fi
}

# ---- the lanes in scope -----------------------------------------------------
# A read that fails refuses the run (exit 4): an unread window list or
# registry would look like "no live lane" and fail open (R7 W3, c-792). The one
# failure read as "no windows" is a socket path that does not exist.
refuse() { echo "lane-test-server-reap: refused, nothing stopped: $*" >&2; exit 4; }
spool_tmux_argv
if ! WINDOWS="$("${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>"$_tmuxerr")"; then
  grep -qE '^error connecting to .*\(No such file or directory\)$' "$_tmuxerr" \
    || refuse "the tmux window list was not read ($(head -1 "$_tmuxerr"))"
  WINDOWS=""
fi
for f in "$R/registry.tsv" "$R/registry.retired.tsv"; do
  [ ! -e "$f" ] || [ -r "$f" ] || refuse "$f exists but cannot be read"
done
# The registries, read once (registry.retired.tsv: 16252 rows, 2687 ids on
# one box, 2026-11-04): LIVE[id] = 1 per registry.tsv row, RET[id] = the
# worktree of its last retired row ("" when that row names none).
# LIVE_WT: the live rows' worktrees named for their id (c-001's /opt is not)
declare -A LIVE=() RET=()
LIVE_WT=()
while IFS=$'\t' read -r k _ _ w _; do
  [ -n "$k" ] || continue
  LIVE["${k%%@*}"]=1
  w="${w%/}"; [[ "$w" == /?* && "${w##*/}" == "${k%%@*}" ]] && LIVE_WT+=("$w")
done \
  < <([ -r "$R/registry.tsv" ] && cat "$R/registry.tsv")
while IFS=$'\t' read -r k _ _ w _; do
  if [ -z "$k" ] || [[ "$k" == \#* ]]; then continue; fi
  [ "$w" = - ] && w=""; RET["${k%%@*}"]="$w"
done < <([ -r "$R/registry.retired.tsv" ] && cat "$R/registry.retired.tsv")
# live_why ID -> why the lane is not proven retired (nothing: it is)
live_why() {
  if grep -E "(^|[^A-Za-z0-9])${1}([^0-9]|\$)" <<<"$WINDOWS" >/dev/null; then echo "live-lane $1 (a tmux window carries it)"; return; fi
  [ "$RETIRING" = 1 ] && return
  if [ -n "${LIVE[$1]:-}" ]; then echo "live-lane $1 (a row in $R/registry.tsv)"; return; fi
  [ -n "${RET[$1]+x}" ] || echo "not-retired $1 (no row in $R/registry.retired.tsv)"
}
L_ID=() L_WT=() L_SLUG=() skipped=0 proven_nowt=0
add_lane() {  # ID [WORKTREE]
  local id="$1" wt="${2:-}" why
  [ -n "$wt" ] || wt="${RET[$id]:-}"
  wt="${wt%/}"
  [ -z "$wt" ] || [[ "$wt" == /?* && "${wt##*/}" == "$id" ]] || {
    echo "lane-test-server-reap: refused: worktree '${wt}' of ${id} is not named for it; its paths reach other lanes'" >&2
    return 2; }
  why="$(live_why "$id")"
  if [ -n "$why" ]; then say "KEEP $why"; return 0; fi
  if [ -z "$wt" ]; then
    [ "$ALL" = 1 ] && { skipped=$((skipped + 1)); return 0; }
    say "KEEP no-worktree $id (no worktree known: only a private clone can place its servers)"
    proven_nowt=1; return 0
  fi
  L_ID+=("$id"); L_WT+=("$wt"); L_SLUG+=("${wt//[^A-Za-z0-9]/-}")
}
if [ "$ALL" = 1 ]; then
  # a row with no worktree, or one not named for its id, is skipped, not the run
  for id in "${!RET[@]}"; do
    [[ "$id" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || continue
    add_lane "$id" 2>/dev/null || skipped=$((skipped + 1))
  done
else
  add_lane "$ID" "$WT_ARG" || exit $?
fi

# ---- the known test servers -------------------------------------------------
# is_test_server ARGV...: an interpreter whose script (first non-option arg)
# has a known name
is_test_server() {
  local a0="${1##*/}" a; shift
  [[ "$a0" =~ ^(node|nodejs|python|python3(\.[0-9]+)?|bun|deno)$ ]] || return 1
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    case "$scripts" in *" ${a##*/} "*) return 0 ;; esac
    return 1
  done
  return 1
}
# in_live_wt PATH: under a live lane's worktree (R7 N1: such a cwd keeps it)
in_live_wt() {
  local w
  for w in "${LIVE_WT[@]}"; do [[ "$1" == "$w" || "$1" == "$w"/* ]] && return 0; done
  return 1
}
# lane_of PATH... -> the index of the lane whose worktree or scratch holds one
lane_of() {
  local p i rest top
  for p in "$@"; do
    [[ "$p" == /* ]] || continue
    for i in "${!L_ID[@]}"; do
      [[ "$p" == "${L_WT[$i]}" || "$p" == "${L_WT[$i]}"/* ]] && { echo "$i"; return 0; }
      rest="${p#"$tmp"/claude-}"
      if [ "$rest" = "$p" ] || [[ ! "${rest%%/*}" =~ ^[0-9]+$ || "$rest" != */* ]]; then continue; fi
      top="${rest#*/}"; top="${top%%/*}"
      [[ "$top" == "${L_SLUG[$i]}" || "$top" == "${L_SLUG[$i]}"-* ]] && { echo "$i"; return 0; }
    done
  done
  return 1
}
# clone_ids PATH... -> the agent id of each private clone a path lies under,
# one per line: the top dir of the tmp roots, <id> or <id>-*. A path with a ..
# component names no clone: where it lands is not what it says
clone_ids() {
  local p root top
  for p in "$@"; do
    [[ "$p" == /* && "/$p/" != */../* ]] || continue
    for root in "$tmp" "$vartmp"; do
      [[ "$p" == "$root"/* ]] || continue
      top="${p#"$root"/}"; top="${top%%/*}"
      [[ "$top" =~ ^${SPOOL_AGENT_ID_RX}(-.*)?$ ]] && echo "${BASH_REMATCH[1]}"
    done
  done
  return 0
}
# clone_why ID -> why this run may not stop a server in its clone (nothing: it may)
clone_why() {
  if [ "$ALL" = 0 ] && [ "$1" != "$ID" ]; then echo "other-lane $1 (this run reaps $ID)"; return; fi
  live_why "$1"
}
stat_of() {  # PID -> "<state> <starttime>"
  local s f; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  read -ra f <<<"${s##*) }"; printf '%s %s' "${f[0]}" "${f[19]}"
}
running() {  # PID START: the same process, not a zombie
  local st; st="$(stat_of "$1")" || return 1
  [ "${st#* }" = "$2" ] && [ "${st%% *}" != Z ]
}
# stop PID OWNER START -> TERM or TERM+KILL; 1 when it still runs
stop() {
  local pid="$1" u="$2" start="$3" n
  running "$pid" "$start" || { echo gone; return 2; }
  as_owner "$u" kill -s TERM "$pid" 2>/dev/null
  for ((n = 0; n < grace * 10; n++)); do running "$pid" "$start" || { echo TERM; return 0; }; sleep 0.1; done
  running "$pid" "$start" && as_owner "$u" kill -s KILL "$pid" 2>/dev/null
  for ((n = 0; n < 30; n++)); do running "$pid" "$start" || { echo TERM+KILL; return 0; }; sleep 0.1; done
  echo failed; return 1
}

# scan_one PID: one process; a known test server gets its line
scan_one() {
  local pid="$1" u cwd i st sig paths=() argv=()
  { mapfile -d '' -t argv <"/proc/$pid/cmdline"; } 2>/dev/null || return 0
  [ "${#argv[@]}" -gt 0 ] && is_test_server "${argv[@]}" || return 0
  [ "$pid" != "$$" ] || return 0
  u="$(stat -c %U "/proc/$pid" 2>/dev/null)" || return 0
  st="$(stat_of "$pid")" || return 0
  # test only: the start time a reused pid would show (R7 W1)
  [ -z "${LANE_TEST_SERVER_START_OVERRIDE:-}" ] || st="${st%% *} $LANE_TEST_SERVER_START_OVERRIDE"
  cwd="$(as_owner "$u" readlink "/proc/$pid/cwd" 2>/dev/null || true)"
  # a swept worktree still places the process: its cwd reads "<dir> (deleted)"
  paths=("${cwd% (deleted)}" "${argv[@]}" "${argv[@]#*=}")
  local args="${argv[*]}" what lane="" clone="" blocked="" c why
  while read -r c; do
    why="$(clone_why "$c")"
    if [ -n "$why" ]; then blocked="${blocked:-$why}"; else clone="${clone:-$c}"; fi
  done < <(clone_ids "${paths[@]}")
  if [ -n "$blocked" ]; then
    if [ "$ALL" = 1 ] || i="$(lane_of "${paths[@]}")" || [ -n "$clone" ]; then
      say "KEEP clone-not-retired pid=$pid user=$u ($blocked) cwd=${cwd:--} args=$args"
    fi
    return 0
  fi
  if i="$(lane_of "${paths[@]}")"; then lane="${L_ID[$i]}"; else lane="$clone"; fi
  if [ -z "$lane" ]; then
    [ "$ALL" = 1 ] && say "KEEP no-retired-lane pid=$pid user=$u cwd=${cwd:--} args=$args"
    return 0
  fi
  what="pid=$pid lane=$lane user=$u"
  if [ -n "$cwd" ] && in_live_wt "${cwd% (deleted)}"; then
    say "KEEP cwd-in-live-lane $what cwd=$cwd args=$args"; return 0
  fi
  case "$users" in *" $u "*) ;; *) say "KEEP not-agent-user $what (agent users:${users% }) cwd=${cwd:--} args=$args"; return 0 ;; esac
  if [ "$APPLY" = 0 ]; then say "PLAN stop $what cwd=${cwd:--} args=$args"; return 0; fi
  if [ "$u" != "$me" ] && [ "$(id -u)" != 0 ] && { [ "$use_sudo" != 1 ] || ! sudo -n -u "$u" true 2>/dev/null; }; then
    say "KEEP no-sudo $what (cannot signal as $u) cwd=${cwd:--} args=$args"; return 0
  fi
  local src=0; sig="$(stop "$pid" "$u" "${st#* }")" || src=$?
  case "$src" in
    0) say "DO stop $what signal=$sig cwd=${cwd:--} args=$args" ;;
    2) say "KEEP gone-or-reused $what (exited, or its pid now names another process: not signalled) cwd=${cwd:--} args=$args" ;;
    *) say "WARN could not stop $what cwd=${cwd:--} args=$args"; rc=3 ;;
  esac
}

rc=0
if [ "${#L_ID[@]}" -gt 0 ] || [ "$ALL" = 1 ] || [ "$proven_nowt" = 1 ]; then
  for d in /proc/[0-9]*; do scan_one "${d#/proc/}"; done
fi
[ "$ALL" = 1 ] && say "OK ${#L_ID[@]} retired lane(s) in scope; ${skipped} skipped (no worktree, or one not named for the id)"
exit "$rc"
