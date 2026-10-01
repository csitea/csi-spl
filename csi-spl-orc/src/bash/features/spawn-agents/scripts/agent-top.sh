#!/usr/bin/env bash
# agent-top.sh — read-only fleet view of the live agent tmux windows, the
# tmux status-line summary, and the window-name state badges. Ported from the
# frozen box engine (specs/048, SPL-1160): the same rows, states, badges and
# status line, with the spool as the mailbox (lib/agent-state.inc.sh).
#
# Rows come from LIVE windows whose name (box tag stripped) starts with an
# agent id; a registry row whose pane is gone is never shown. Identity and kind
# come from the pane's process tree (agent_of_ps: a spawn-/restore-<kind>.sh
# <ID> argv, else the id the run-as hop exports), not from the title; a window
# whose tree holds no agent reads "ended". Orchestrators (xxx-00, ORC-n, @agent-role orc) are listed, never badged.
#
# Usage:
#   agent-top.sh                      # one-shot table
#   agent-top.sh --watch              # reprint every --interval seconds
#   agent-top.sh --status-line        # one compact line for tmux status-right
#   agent-top.sh --badges             # badge every non-orchestrator window once
#   agent-top.sh --badge-loop         # badge every --interval seconds (default 15)
#   agent-top.sh --ensure-badge-loop  # start --badge-loop unless one is running
#   agent-top.sh --interval N
#
# Env (an unset one is read from ${XDG_CONFIG_HOME:-~/.config}/spool-agent/env
# when that file sets it - tmux run-shell starts this with a bare environment):
#   SPOOL_TMUX_SOCKET        the server (default: $TMUX, else /tmp/tmux-<uid>/default)
#   SPOOL_ROOT               spool root (default /var/spool-hub)
#   SPOOL_ORCHESTRATOR_ID    whose inbox holds the agents' reports (default CLE-00)
#   SPOOL_LEGACY_INBOX_ROOT  during a switch-over: the older markdown message
#                            root (its registry and <ID>/outbox are read too)
#   SPOOL_BOX_TAG            the box tag; unset = the tag most agent windows carry
#   AGENT_TOP_PIDFILE        the badge loop's pidfile (default /tmp/agent-top-badge-loop.pid,
#                            the same file the frozen engine's copy uses, so at
#                            most one badge loop of either copy runs)
#
# Never calls select-window or refresh-client.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/spool-agent/env"
for v in SPOOL_TMUX_SOCKET SPOOL_ROOT SPOOL_ORCHESTRATOR_ID SPOOL_LEGACY_INBOX_ROOT SPOOL_BOX_TAG; do
  [ -n "${!v:-}" ] || [ ! -r "$CFG" ] && continue
  val="$( . "$CFG" >/dev/null 2>&1; printf '%s' "${!v:-}" )"
  [ -n "$val" ] && export "$v=$val"
done
# shellcheck source=../lib/agent-state.inc.sh
. "$HERE/../lib/agent-state.inc.sh"
SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"

INTERVAL=5 MODE=table
while [ "$#" -gt 0 ]; do
  case "$1" in
    --watch)       MODE=watch; shift ;;
    --status-line) MODE=status; shift ;;
    --badges)      MODE=badges; shift ;;
    --badge-loop)  MODE=badge-loop; INTERVAL=15; shift ;;
    --ensure-badge-loop) MODE=ensure-loop; INTERVAL=15; shift ;;
    --interval)    INTERVAL="${2:?agent-top: --interval needs seconds}"; shift 2 ;;
    --interval=*)  INTERVAL="${1#*=}"; shift ;;
    -h|--help)     sed -n '/^# Usage:/,/^# Env/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "agent-top: unknown arg: $1" >&2; exit 2 ;;
  esac
done

sock="${TMUX:-}"; sock="${sock%%,*}"
[ -n "$sock" ] || sock="${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}"
SOCK_OWNER="$(stat -c %U "$sock" 2>/dev/null || true)"
if [ -n "$SOCK_OWNER" ] && [ "$SOCK_OWNER" != "$(id -un)" ]; then TM=(sudo -n -u "$SOCK_OWNER" tmux -u -S "$sock")
else TM=(tmux -u -S "$sock"); fi   # -u: a C-locale client prints non-ASCII names as "_"
if ! "${TM[@]}" list-windows -a -F '#{window_id}' >/dev/null 2>&1; then
  echo "ERROR: tmux server at ${sock} does not answer as $(id -un)." >&2
  echo "       An unreachable server would look like an empty fleet." >&2
  exit 2
fi
PIDFILE="${AGENT_TOP_PIDFILE:-/tmp/agent-top-badge-loop.pid}"

# No tag configured: take the one most agent windows carry, so the badge loop
# never strips a tag the box has always shown.
if [ -z "$(an_tag)" ]; then
  AGENT_TOP_TAG="$("${TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null \
    | sed -nE -e 's/^([A-Za-z0-9][A-Za-z0-9._-]*): (CLE|GRK|AGY|QWN)-[0-9]+.*/\1/p' -e 's/^(CLE|GRK|AGY|QWN)-[0-9]+@([a-z0-9][a-z0-9-]*).*/\2/p' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
fi

registry_row() {  # ID PANE LIVE-PANES -> the registry row of that pane, else the newest live one of ID
  local id="$1" pane="$2" live="$3" reg row p
  for reg in "$SPOOL_ROOT/registry.tsv" ${SPOOL_LEGACY_INBOX_ROOT:+"$SPOOL_LEGACY_INBOX_ROOT/registry.tsv"}; do
    [ -r "$reg" ] || continue
    row="$(awk -F '\t' -v pane="$pane" '$3 == pane { rec = $0 } END { if (rec != "") print rec }' "$reg")"
    [ -n "$row" ] && { printf '%s\n' "$row"; return; }
  done
  for reg in "$SPOOL_ROOT/registry.tsv" ${SPOOL_LEGACY_INBOX_ROOT:+"$SPOOL_LEGACY_INBOX_ROOT/registry.tsv"}; do
    [ -r "$reg" ] || continue
    while IFS= read -r row; do
      p="$(printf '%s' "$row" | cut -f3)"
      [ -n "$p" ] && printf '%s\n' "$live" | grep -qxF "$p" && { printf '%s\n' "$row"; return; }
    done < <(awk -F '\t' -v id="$id" '$1 == id' "$reg" | tac)
  done
}

trunc() { local s="$1" n="$2"; if [ "${#s}" -le "$n" ]; then printf '%s' "$s"; else printf '%s' "${s:0:$((n - 1))}…"; fi; }

# ONE snapshot of every window's first pane: index, name, window id, role, and
# that pane's id + pid, all from the SAME tmux call. The pane id is what a
# badge renames, so it must be read together with the name it is computed
# from. This used to read the window list once and then look each pane up
# again BY INDEX (`list-panes -t session:index`), seconds later on a busy
# fleet. A spawn in between fires the sorter, which swap-windows and shifts
# every later index by one, so each lookup found the NEIGHBOUR's pane and the
# badge wrote one agent's name onto the next agent's window (2026-10-01: six to
# nine windows shifted by one after every spawn).
_window_panes() {  # -> target|name|window_id|role|pane_id|pane_pid, first pane per window
  "${TM[@]}" list-panes -a -F '#{session_name}:#{window_index}|#{window_name}|#{window_id}|#{@agent-role}|#{pane_id}|#{pane_pid}' 2>/dev/null \
    | awk -F'|' '!seen[$3]++'
}

collect_rows() {  # TSV: id kind state window branch rundir pending pane target
  local live target wname role bare id pane pid sid launch has_launcher kind is_orc n scr row rundir branch snap
  live="$("${TM[@]}" list-panes -a -F '#{pane_id}' 2>/dev/null)"
  snap="$(_window_panes)"
  # Test seam: runs once between the snapshot and the per-window work, where a
  # spawn + sort lands on a live box. Unset in production.
  [ -n "${AGENT_TOP_AFTER_SNAPSHOT:-}" ] && bash -c "$AGENT_TOP_AFTER_SNAPSHOT" >/dev/null 2>&1
  while IFS='|' read -r target wname _wid role pane pid; do
    [ -n "$pane" ] || continue
    bare="$(an_strip "$wname")"
    printf '%s' "$bare" | grep -qE '^(CLE|GRK|AGY|QWN)-[0-9]+' || continue
    id="$(printf '%s' "$bare" | grep -oE '^[A-Za-z]+-[0-9]+')"
    has_launcher=0 kind=- launch=""
    if [ -n "$pid" ]; then
      sid="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')"
      [ -n "$sid" ] && launch="$(ps -o args= -g "$sid" 2>/dev/null | agent_of_ps)"
      if [ -n "$launch" ]; then has_launcher=1; id="${launch##* }"; kind="${launch%% *}"; fi
    fi
    is_orc=0; agent_is_orc "$bare" "$role" && is_orc=1
    n="$(pending_count "$id")"
    scr=""
    [ "$has_launcher" = 1 ] && [ "$is_orc" != 1 ] && scr="$("${TM[@]}" capture-pane -p -t "$pane" 2>/dev/null || true)"
    row="$(registry_row "$id" "$pane" "$live")"
    rundir=-
    if [ -n "$row" ]; then
      [ "$kind" = - ] && kind="$(printf '%s' "$row" | cut -f2)"
      rundir="$(printf '%s' "$row" | cut -f4)"
    fi
    branch=-
    if [ -n "$rundir" ] && [ "$rundir" != - ] && [ -d "$rundir" ]; then
      branch="$(git -C "$rundir" symbolic-ref --short HEAD 2>/dev/null || true)"
      [ -n "$branch" ] || branch=-
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${kind:--}" \
      "$(classify_agent "$id" "$scr" "$has_launcher" "$n" "$is_orc")" "$wname" "$branch" "${rundir:--}" \
      "$(pending_age "$id")" "$pane" "$target"
  done <<< "$snap"
}

count_states() {  # rows on stdin -> "n busy dialog awaiting ended idle orc"
  awk -F '\t' '{ n++; c[$3]++ } END { printf "%d %d %d %d %d %d %d\n", n, c["busy"], c["dialog"], c["awaiting"], c["ended"], c["idle"], c["orc"] }'
}

print_table() {
  local rows id kind state wname branch rundir pending
  rows="$(cat)"
  printf '%-9s %-7s %-9s %-36s %-22s %-36s %s\n' ID KIND STATE WINDOW BRANCH RUNDIR PENDING
  while IFS=$'\t' read -r id kind state wname branch rundir pending _; do
    [ -n "$id" ] || continue
    printf '%-9s %-7s %-9s %-36s %-22s %-36s %s\n' "$id" "$kind" "$state" "$(trunc "$wname" 36)" \
      "$(trunc "$branch" 22)" "$(trunc "$rundir" 36)" "$pending"
  done <<<"$rows"
  read -r n b d a e i o < <(printf '%s' "$rows" | grep . | count_states)
  printf 'n=%s live windows  (busy=%s dialog=%s awaiting=%s ended=%s idle=%s orc=%s)\n' "${n:-0}" "${b:-0}" "${d:-0}" "${a:-0}" "${e:-0}" "${i:-0}" "${o:-0}"
}

print_status() {
  read -r n b d a e i o < <(grep . | count_states)
  printf 'agents %s  >%s ?%s !%s .%s  orc=%s\n' "${n:-0}" "${b:-0}" "$(( ${d:-0} + ${a:-0} ))" "${e:-0}" "${i:-0}" "${o:-0}"
}

apply_badges() {
  local id kind state wname branch rundir pending pane target want new
  while IFS=$'\t' read -r id kind state wname branch rundir pending pane target; do
    [ "$state" = orc ] && continue
    [ -n "$pane" ] || continue
    want="$(badge_for_state "$state")"
    # Canonical form ("<tag>: <ID> <badge> <title>") is enforced only on a box
    # that HAS a tag; with none, a right badge leaves the name alone.
    [ "$want" = "$(name_badge "$wname")" ] && [ -z "$(an_tag)" ] && continue
    new="$(an_with_badge "$wname" "$want")"
    [ "$new" = "$wname" ] && continue
    # A badge only re-decorates the name a window already has: it never writes
    # an id the process in that pane does not carry ($id is the process's id
    # when a launcher or run-as env was found, else the name's own).
    [ "$(printf '%s' "$(an_strip "$wname")" | grep -oE '^[A-Za-z]+-[0-9]+')" = "$id" ] || continue
    # Compare-and-set: the window must still carry the name this badge was
    # computed from. Anything that renamed it since (a sort is harmless, it
    # moves the pane with its window; a riname or a human is not) wins.
    [ "$("${TM[@]}" display-message -p -t "$pane" '#{window_name}' 2>/dev/null)" = "$wname" ] || continue
    # The pane, never the title or an index, is the target; a window only.
    "${TM[@]}" set-window-option -t "$pane" automatic-rename off >/dev/null 2>&1
    "${TM[@]}" rename-window -t "$pane" "$new" >/dev/null 2>&1
  done
}

case "$MODE" in
  table)  collect_rows | print_table ;;
  status) collect_rows | print_status ;;
  badges) collect_rows | apply_badges; collect_rows | print_table ;;
  watch)  while true; do date -u +%Y-%m-%dT%H:%M:%SZ; collect_rows | print_table; sleep "$INTERVAL"; done ;;
  ensure-loop)
    # A live pid in the pidfile - this copy's loop or the frozen engine's - wins.
    # Not pgrep: tmux run-shell's `sh -c "... --badge-loop"` would match itself.
    # The check and the start run under one lock: hooks fire this several times
    # at once (attach, new session), and each unlocked caller saw no live pid
    # and started its own loop - three ran side by side on 2026-10-01.
    exec 8>>"$PIDFILE.lock" 2>/dev/null && { flock -w 5 8 || exit 0; }
    old="$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$old" ] && kill -0 "$old" 2>/dev/null && exit 0
    nohup bash "$HERE/agent-top.sh" --badge-loop --interval "$INTERVAL" >/dev/null 2>&1 8>&- &
    echo $! > "$PIDFILE.$$" && mv -f "$PIDFILE.$$" "$PIDFILE"
    ;;
  badge-loop)
    # Never a bare `echo $$ > PIDFILE`: that truncates then writes, OUTSIDE the
    # ensure lock, and a locked reader in between saw an empty file and started
    # a second loop (3 loops under load ~60, CLE-77907). ensure-loop already
    # wrote this pid; a loop started by hand writes it atomically.
    [ "$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')" = "$$" ] ||
      { echo $$ > "$PIDFILE.$$" && mv -f "$PIDFILE.$$" "$PIDFILE"; }
    trap '[ "$(cat "$PIDFILE" 2>/dev/null | tr -d "[:space:]")" = "$$" ] && rm -f "$PIDFILE"' EXIT
    while true; do collect_rows | apply_badges || true; sleep "$INTERVAL"; done ;;
esac
