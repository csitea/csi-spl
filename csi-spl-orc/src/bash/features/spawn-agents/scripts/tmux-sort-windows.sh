#!/usr/bin/env bash
# Ported from the frozen box engine's tmux-windows feature (specs/048,
# SPL-1160): the same order, lock and never-move-the-human rules, on this
# feature's resolver (lib/spool-env.inc.sh) and tag rule (lib/agent-state.inc.sh).
#
# tmux-sort-windows.sh — keep tmux windows in a deterministic order.
#
# Invoked four ways:
#   * by hand           : tmux-sort-windows.sh [--dry-run] [--session main]
#   * from a tmux hook  : tmux-sort-windows.sh --hook      (after-new-window,
#                         after-rename-window, window-(un)linked — see
#                         tmux-windows.conf)
#   * from a spawner    : after it has renamed the fresh window
#   * by the owner, exactly once, after flipping @window-sort-enabled back on
#
# ORDER (option @window-sort-order, or $WINDOW_SORT_ORDER):
#   agents-first (default)  AGY-01, CLE-00, c-004, CLE-10, CLE-422, GRK-01, q-007, bash, sudo
#   agents-last             bash, sudo, AGY-01, CLE-00, …
#   plain                   pure natural sort, agent and plain windows intermixed
#
# Within each rank the key is a NATURAL sort (digit runs compared numerically),
# so CLE-10 sorts before CLE-422 — a plain lexical sort puts CLE-422 first, and
# that was the whole reason the fleet's window bar was unreadable.
#
# Names are ranked with the box tag REMOVED (an_strip, lib/agent-state.inc.sh): the tag
# is display only, so "box1: CLE-07 wip" ranks as the agent CLE-07, not as a
# plain window that starts with "b". A badge written in front of the tag by an
# older riname ("! box1: CLE-00 …") is read the same way.
#
# THREE THINGS THIS SCRIPT MUST NEVER DO
# --------------------------------------
# 1. Move the human off the window they are looking at. `swap-window -d` leaves
#    the session's current-window POINTER on its index, so swapping the contents
#    of that index silently teleports an attached client into another agent's
#    pane. We therefore record the active window_id per session up front and
#    re-select it afterwards ONLY if it actually moved. (This is the opposite of
#    the no-steal-focus rule, which forbids yanking a client onto a NEW window.)
# 2. Re-enter itself. The hooks fire on rename, and a sort is a burst of tmux
#    commands; a per-socket flock makes a concurrent hook a no-op instead of a
#    swap storm. A hook that loses the race leaves a "pending" mark first, and
#    the holder runs one more pass for it before letting go — so the LAST
#    window created in a burst is always sorted, not just the first.
# 3. Address a window by INDEX. Indices are not stable across a sort — only
#    #{window_id} (@12) and #{pane_id} (%34) are. Every swap here names two
#    window ids, sessions are named by session id, and every caller must
#    capture a pane or window id, never "session:index".
#
# PAUSING: `@window-sort-enabled 0` stops every sort. It is re-read before
# EVERY pass, so a sort already running stops at its next pass too.
#
# Config (env vars / tmux options, all with generic defaults):
#   --socket PATH       the server to sort; else $TMUX, else $SPOOL_TMUX_SOCKET
#   SPOOL_BOX_USER      the server owner; tmux calls hop to it when needed
#   WINDOW_SORT_ORDER   agents-first | agents-last | plain    (default: agents-first)
#   WINDOW_SORT_DEBOUNCE  seconds to settle before sorting    (default: 0.35 on --hook)
#   WINDOW_SORT_DEBUG=<file>  append every decision to <file>
#   @window-sort-enabled  tmux option; 0 disables without editing hooks
#   @window-sort-order    tmux option; wins over WINDOW_SORT_ORDER
set -uo pipefail

TW_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$TW_DIR/../lib/spool-env.inc.sh"
# shellcheck source=../lib/agent-state.inc.sh
. "$TW_DIR/../lib/agent-state.inc.sh"

tw_socket() {  # [PATH] -> TW_SOCK and TM=( tmux -u ... ), hopping to the owner
  TW_SOCK="${1:-}"
  if [ -z "$TW_SOCK" ]; then TW_SOCK="${TMUX:-}"; TW_SOCK="${TW_SOCK%%,*}"; fi
  [ -n "$TW_SOCK" ] || TW_SOCK="$SPOOL_TMUX_SOCKET"
  # -n: a hook must fail, never hang on a password prompt nobody can see.
  # -u: a C-locale client prints each TAB and non-ASCII byte of -F as "_".
  TM=(tmux -u -S "$TW_SOCK")
  [ "$(id -un)" = "$SPOOL_BOX_USER" ] || TM=(sudo -n -u "$SPOOL_BOX_USER" tmux -u -S "$TW_SOCK")
}
# Asked through the owner hop, not with `[ -S ]`: the socket dir is mode 0700.
tw_alive() { "${TM[@]}" list-sessions >/dev/null 2>&1; }
# Keyed on the SOCKET: a busy fleet server never makes a scratch sort a no-op.
tw_lock_file() {  # NAME
  printf '%s/.tmux-%s.%s.lock' "${TMUX_WINDOWS_LOCK_DIR:-/tmp}" "$1" \
    "$(printf '%s' "$TW_SOCK" | tr -c 'A-Za-z0-9' '_')"
}
# Open PATH READ-ONLY on FD: flock(2) needs no write access, and a read-only
# open never trips fs.protected_regular on a file another user created in
# sticky /tmp - hooks run as the server owner, a hand-run sort maybe not.
tw_lock_open() {  # FD PATH
  [ -e "$2" ] || ( umask 000; : >> "$2" ) 2>/dev/null
  eval "exec $1<\"\$2\"" 2>/dev/null
}

DRY_RUN=0
HOOK=0
SESSION_ARG=""
SOCKET_ARG=""
VERBOSE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1; shift ;;
    --hook)       HOOK=1; shift ;;
    --session)    SESSION_ARG="${2:?--session requires a name}"; shift 2 ;;
    --session=*)  SESSION_ARG="${1#*=}"; shift ;;
    --socket)     SOCKET_ARG="${2:?--socket requires a path}"; shift 2 ;;
    --socket=*)   SOCKET_ARG="${1#*=}"; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)    sed -n '/^# tmux-sort-windows\.sh — /,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) echo "tmux-sort-windows: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# A hook fired on a TEST's scratch server inherits the test's SPOOL_TEST=1 but
# not always its SPOOL_ROOT (a server started without -f /dev/null loads the
# box's tmux.conf, whose hooks call this script), and the spool guard then
# refuses the live root and turns the suite red. The sorter writes nothing
# under the spool root, so under a test with no root of its own it takes a
# throwaway one and sorts only the server it was named (--socket, else the
# hook's $TMUX) - never the live default socket.
tw_test_context() {
  [ "${SPOOL_TEST:-}" = 1 ] || return 0
  local live
  live="$(readlink -m -- "${SPOOL_LIVE_ROOT:-/var/spool-hub}")"
  [ "$(readlink -m -- "${SPOOL_ROOT:-$live}")" = "$live" ] || return 0
  local sock="${SOCKET_ARG:-${TMUX%%,*}}"
  case "$sock" in ''|/tmp/tmux-[0-9]*/default) exit 0 ;; esac
  SPOOL_ROOT="${TMPDIR:-/tmp}/.tmux-sort-windows.no-spool-root"
}
TMUX="${TMUX:-}"
tw_test_context
SPOOL_ENV_NO_BINS=1 spool_env_resolve

log() { [ "$VERBOSE" = 1 ] && echo "tmux-sort-windows: $*" >&2; return 0; }
# Hooks run detached with nowhere to print, so a wrong bar is otherwise
# unobservable. WINDOW_SORT_DEBUG=<file> makes every decision inspectable.
dbg() { [ -n "${WINDOW_SORT_DEBUG:-}" ] && printf '%s [%s] %s\n' "$(date +%T.%3N)" "$$" "$*" >> "$WINDOW_SORT_DEBUG" 2>/dev/null; return 0; }

tw_socket "$SOCKET_ARG"
tw_alive || { log "no tmux server at $TW_SOCK"; exit 0; }
dbg "ENTER hook=$HOOK dry=$DRY_RUN sock=$TW_SOCK ppid=$PPID"

# The master switch, re-read before every pass (see PAUSING above).
sort_enabled() {
  case "$("${TM[@]}" show-options -gqv @window-sort-enabled 2>/dev/null)" in
    0|off|no|false) return 1 ;;
  esac
  return 0
}

# tmux option wins over the env var so it can be flipped live without a re-source.
ORDER="$("${TM[@]}" show-options -gqv @window-sort-order 2>/dev/null)"
ORDER="${ORDER:-${WINDOW_SORT_ORDER:-agents-first}}"
case "$ORDER" in
  agents-first|agents-last|plain) ;;
  *) echo "tmux-sort-windows: bad order '$ORDER' (agents-first|agents-last|plain)" >&2; exit 1 ;;
esac

# --- the rows and their sort key -------------------------------------------
# "id<TAB>index<TAB>name<TAB>key" per window of SESSION, the name with the box
# tag removed. an_strip forks, so it only runs on a name that could carry a tag
# or a misplaced badge; every other name is used as it is.
#
# KEY is the name with a leading spec 061 agent id spelled in its kind's legacy
# prefix: "c-004 x" keys as "CLE-004 x", so c-NNN and CLE-NNNN sort as ONE kind,
# numerically (CLE-001, CLE-003, c-004, CLE-222), and q-007 sorts with QWN, not
# after GRK. Compared raw, "c-" sorts below "cl" and every new window jumped
# ahead of CLE-001..003. The grammar and the kind map are spool-env.inc.sh's
# (the reader grammar: readers take both forms whatever the clock).
_sort_key() {  # NAME -> KEY
  local n="$1" id kind pfx
  if [[ "$n" =~ ^${SPOOL_AGENT_ID_NEW_RX}($|[^0-9]) ]]; then
    id="${n:0:5}"
    kind="$(spl_kind_of_agent_id "$id")" && pfx="$(spool_prefix_of_kind "$kind")" \
      && n="${pfx}-${n#?-}"
  fi
  printf '%s' "$n"
}

_rows() {  # SESSION
  local id idx name
  "${TM[@]}" list-windows -t "$1" -F '#{window_id}	#{window_index}	#{window_name}' 2>/dev/null \
  | while IFS='	' read -r id idx name; do
      [ -n "$id" ] || continue
      case "$name" in *": "*|*@*|'> '*|'? '*|'! '*) name="$(an_strip "$name")" ;; esac
      printf '%s\t%s\t%s\t%s\n' "$id" "$idx" "$name" "$(_sort_key "$name")"
    done
}

# Emits "<rank>|<natural-key>\t<window_id>" for each "id<TAB>index<TAB>name<TAB>key" row.
sort_keys() {
  awk -F'\t' -v order="$ORDER" '
    function natkey(s,   out, i, c, run, isdig) {
      out = ""; run = ""; isdig = -1
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c ~ /[0-9]/) {
          if (isdig == 0) { out = out tolower(run); run = "" }
          isdig = 1; run = run c
        } else {
          if (isdig == 1) { out = out sprintf("%012d", run + 0); run = "" }
          isdig = 0; run = run c
        }
      }
      if (isdig == 1) out = out sprintf("%012d", run + 0)
      else if (isdig == 0) out = out tolower(run)
      return out
    }
    {
      name = $4
      is_agent = (name ~ /^[A-Za-z]+-[0-9]+/) ? 1 : 0
      if (order == "plain")            rank = 0
      else if (order == "agents-last") rank = is_agent ? 1 : 0
      else                             rank = is_agent ? 0 : 1
      # The window id breaks a tie between equal names, so two windows with
      # the same name never trade places on every pass. \001 sorts below every
      # printable byte, so "CLE-07" still sorts before "CLE-07 wip".
      printf "%d\001%s\001%012d\t%s\n", rank, natkey(name), substr($1, 2) + 0, $1
    }'
}

sort_one_session() {
  local sess="$1" attempt=0
  # Bounded retry: a pass computed from a bar that another writer moved
  # underneath converges on the next read rather than leaving a half-sorted bar.
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    _sort_pass "$sess" || return 0     # nothing to do, paused, or aborted
    [ "$DRY_RUN" = 1 ] && return 0
    _is_sorted "$sess" && return 0     # converged
    dbg "$sess: not converged after pass $attempt — retrying"
  done
  return 0
}

# True when the session's window order already equals the desired order.
_is_sorted() {
  local sess="$1" rows want have
  rows="$(_rows "$sess")"
  [ -n "$rows" ] || return 0
  want="$(printf '%s\n' "$rows" | sort_keys | LC_ALL=C sort -t'	' -k1,1 | cut -f2 | tr '\n' ' ')"
  have="$(printf '%s\n' "$rows" | LC_ALL=C sort -t'	' -k2,2n | cut -f1 | tr '\n' ' ')"
  [ "$want" = "$have" ]
}

# One pass: read the bar ONCE, compute the whole permutation in memory, then
# apply every swap in a SINGLE tmux invocation.
#
# WHY THE WHOLE PLAN, AND WHY ONE INVOCATION
# ------------------------------------------
# The obvious selection sort — look up where a window is now, swap it, look up
# the next — interleaves reads and writes against a server other clients are
# also driving. Two sorters racing (a rename hook and a new-window hook fire
# ~0.4s apart) then each apply half a permutation computed from a bar the other
# has already moved, and the result is a bar that is sorted by neither. That is
# not a theoretical race: it reordered a correctly-sorted pair back to front in
# roughly one run in four, and it is why this function no longer re-queries
# tmux between swaps. It simulates the swaps locally instead, and hands tmux one
# command list, which the server runs as a single unit of work.
_sort_pass() {
  local sess="$1"
  sort_enabled || { dbg "$sess: paused (@window-sort-enabled)"; log "disabled via @window-sort-enabled"; return 1; }
  local rows
  rows="$(_rows "$sess")"
  [ -n "$rows" ] || return 1

  local -a idxs desired cmds
  # Slots to fill: the session's REAL indices, ascending. They need not be
  # contiguous (base-index 0, renumber-windows off, a killed window leaves a
  # hole), so we reorder the OCCUPANTS of the existing slots and never renumber.
  mapfile -t idxs    < <(printf '%s\n' "$rows" | cut -f2 | LC_ALL=C sort -n)
  mapfile -t desired < <(printf '%s\n' "$rows" | sort_keys | LC_ALL=C sort -t'	' -k1,1 | cut -f2)
  dbg "$sess idxs=[${idxs[*]}] desired=[${desired[*]}]"
  [ "${#idxs[@]}" -eq "${#desired[@]}" ] || { dbg "$sess ABORT: idx/desired length mismatch"; return 1; }

  # Local model of the bar: at[<index>]=<window id>, pos[<window id>]=<index>
  local -A at pos
  local id idx
  while IFS='	' read -r id idx _; do
    [ -n "$id" ] || continue
    at[$idx]="$id"; pos[$id]="$idx"
  done <<< "$rows"

  local k slot want cur swaps=0
  for k in "${!desired[@]}"; do
    slot="${idxs[$k]}"
    want="${desired[$k]}"
    cur="${pos[$want]:-}"
    [ -n "$cur" ] || continue
    [ "$cur" = "$slot" ] && continue
    local other="${at[$slot]:-}"
    if [ "$DRY_RUN" = 1 ]; then
      echo "would swap $want <-> ${other:-<empty>}   (index $cur -> $slot)"
    else
      # Address both ends by WINDOW ID, never by index. An index means
      # "whatever is sitting there when this command runs" — so an
      # index-addressed plan is only correct if nothing else touches the bar
      # between planning and execution, which is precisely what cannot be
      # assumed on a server driven by hooks and other clients. `swap-window
      # -s @a -t @b` exchanges those two windows whatever their indices are,
      # so the plan means the same thing whenever it runs.
      [ -n "$other" ] || continue
      [ "$swaps" -gt 0 ] && cmds+=(";")
      cmds+=(swap-window -d -s "$want" -t "$other")
    fi
    # Apply the swap to the local model, exactly as tmux will apply it.
    at[$slot]="$want"; pos[$want]="$slot"
    if [ -n "$other" ]; then at[$cur]="$other"; pos[$other]="$cur"; else unset 'at[$cur]'; fi
    swaps=$((swaps + 1))
  done

  [ "$DRY_RUN" = 1 ] && return 0
  [ "$swaps" -eq 0 ] && return 0

  # guard 1: remember what the human is actually looking at, because
  # `swap-window -d` keeps the current-window pointer on its INDEX — swapping
  # the contents of that index teleports an attached client into another
  # agent's pane.
  local active_before active_after
  active_before="$("${TM[@]}" display-message -p -t "$sess" '#{window_id}' 2>/dev/null)"

  dbg "$sess plan: ${cmds[*]}"
  "${TM[@]}" "${cmds[@]}" 2>/dev/null || true

  active_after="$("${TM[@]}" display-message -p -t "$sess" '#{window_id}' 2>/dev/null)"
  if [ -n "$active_before" ] && [ "$active_before" != "$active_after" ]; then
    "${TM[@]}" select-window -t "$active_before" 2>/dev/null || true
  fi
  log "$sess: $swaps swap(s)"
  return 0
}

sort_all() {
  sort_enabled || { dbg "paused (@window-sort-enabled)"; log "disabled via @window-sort-enabled"; return 0; }
  if [ -n "$SESSION_ARG" ]; then
    sort_one_session "$SESSION_ARG"
    return 0
  fi
  local s
  while read -r s; do
    [ -n "$s" ] || continue
    sort_one_session "$s"
  done < <("${TM[@]}" list-sessions -F '#{session_id}' 2>/dev/null)
}

# --- guard 2: never re-enter, never lose the last window of a burst ---------
LOCK="$(tw_lock_file sort-windows)"
PENDING="${LOCK}.pending"
HAVE_LOCK=0
if [ "$DRY_RUN" = 0 ] && command -v flock >/dev/null 2>&1 && tw_lock_open 9 "$LOCK"; then
  if [ "$HOOK" = 1 ]; then
    # Mark the bar dirty BEFORE trying the lock. Either the holder sees the
    # mark when it lets go and sorts again, or it has already let go and this
    # flock succeeds: no ordering loses the window that fired this hook.
    touch "$PENDING" 2>/dev/null || true
    flock -n 9 || { dbg "SKIP: lock held, pending mark left"; exit 0; }
    # A create-then-rename burst (every spawner does exactly that) would
    # otherwise sort twice, the first time under the placeholder name.
    sleep "${WINDOW_SORT_DEBOUNCE:-0.35}" 2>/dev/null || true
  else
    # A hand-run, spawner-run or pause-end sort must not silently do nothing
    # just because a hook happened to be mid-flight. Wait for it, briefly.
    flock -w 5 9 || { log "timed out waiting for the sort lock"; exit 0; }
  fi
  HAVE_LOCK=1
fi

passes=0
while :; do
  passes=$((passes + 1))
  stuck=0
  if [ "$HAVE_LOCK" = 1 ]; then
    rm -f "$PENDING" 2>/dev/null
    # Another user's mark in sticky /tmp cannot be removed by us; do not spin on it.
    [ -e "$PENDING" ] && stuck=1
  fi
  sort_all
  [ "$HAVE_LOCK" = 1 ] || break
  flock -u 9
  [ -e "$PENDING" ] && [ "$stuck" = 0 ] && [ "$passes" -lt 10 ] || break
  flock -n 9 || break          # someone else took it: they sort for the mark
  dbg "pending mark: pass $((passes + 1))"
done
exit 0
