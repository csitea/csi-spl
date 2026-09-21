#!/usr/bin/env bash
#------------------------------------------------------------------------------
# pane-seen.sh — "is this text VISIBLE in that agent's terminal?", as one
# answer, for anything that needs to assert specs/028 from outside bash.
#
# The WUI acceptance bot (specs/031) is a node process driving a browser; it
# cannot read tmux, and a second copy of these rules in JavaScript would drift
# from the ones desk-probe.py and spool-notify.sh already agree on. So the
# rules stay here, in one script, and the bot shells out to it.
#
# The rules, each of which exists because the naive version is wrong:
#   - the agent's pane is the one whose WINDOW NAME carries the id, after an
#     optional "<box tag>: " prefix (lib/spool-env.inc.sh spool_id_of_window)
#   - an agent pane painting a TUI legitimately refuses a poke, so the notice
#     pane (pane option @spool_notices == the agent id, CLE-3434) is searched
#     too. Either one showing the text is "visible".
#   - capture-pane HARD WRAPS and can split a word across lines, so a raw
#     substring assert gives false negatives AND, on a short needle, false
#     positives. Both sides are compared with all whitespace removed.
#   - a busy pane scrolls a notice off the screen in seconds, so the capture
#     takes the recent scrollback (-S -500), not just what is on screen.
#
# Usage:
#   pane-seen.sh --agent CLE-00 --needle 'case 1/7 …' [--timeout 30] [--sock PATH]
#
# Prints ONE json line: {"agent":…,"seen":true|false,"pane":…,"kind":"agent"|
# "notice","ms":…,"seconds":…,"panes":{…}}. Exit 0 when seen, 1 when not, 2 on
# a usage error. --quiet drops the line and leaves only the exit code.
#
# `ms` exists because `seconds` cannot answer the question that is actually
# asked of it. The owner's budget for a message becoming visible is 0.3 s, and
# a whole-second field reports every healthy delivery as "0" — indistinguishable
# from 0.9 s, which is three times over. It is still an UPPER BOUND, not an
# instrumented figure: it includes this script's 0.25 s poll and its caller's
# round trip, so it can only ever say "no worse than".
#------------------------------------------------------------------------------
set -uo pipefail

agent='' needle='' timeout=30 quiet=0
sock="${SPOOL_TMUX_SOCK:-/tmp/tmux-$(id -u)/default}"
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   agent="${2:-}"; shift 2 ;;
    --needle)  needle="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --sock)    sock="${2:-}"; shift 2 ;;
    --quiet)   quiet=1; shift ;;
    *) echo "pane-seen.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$agent" ]  || { echo "pane-seen.sh: --agent is required" >&2; exit 2; }
[ -n "$needle" ] || { echo "pane-seen.sh: --needle is required" >&2; exit 2; }
case "$timeout" in ''|*[!0-9]*) echo "pane-seen.sh: --timeout must be a whole number" >&2; exit 2 ;; esac
command -v tmux >/dev/null 2>&1 || { echo "pane-seen.sh: no tmux on PATH" >&2; exit 2; }

tm() { tmux -u -S "$sock" "$@" 2>/dev/null; }

# flatten: strip EVERY whitespace character, so a hard wrap cannot hide a match
flatten() { tr -d '[:space:]'; }

# The pane whose window name carries the agent id, ignoring a "<tag>: " prefix.
agent_pane() {
  tm list-panes -a -F '#{pane_id}	#{window_name}' | while IFS=$'\t' read -r p n; do
    n="${n##*: }"
    [ "${n%% *}" = "$agent" ] && { printf '%s' "$p"; return 0; }
  done
}

# The notice pane split into that agent's window, marked with @spool_notices.
notice_pane() {
  tm list-panes -a -F '#{pane_id}	#{@spool_notices}' | while IFS=$'\t' read -r p m; do
    [ "$m" = "$agent" ] && { printf '%s' "$p"; return 0; }
  done
}

json_str() { printf '%s' "${1:-}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

ap="$(agent_pane)" np="$(notice_pane)"
want="$(printf '%s' "$needle" | flatten)"
[ -n "$want" ] || { echo "pane-seen.sh: --needle is only whitespace" >&2; exit 2; }

now_ms() { date +%s%3N; }
start=$(now_ms) seen_pane='' seen_kind=''
while :; do
  for pair in "notice:$np" "agent:$ap"; do
    kind="${pair%%:*}" pane="${pair#*:}"
    [ -n "$pane" ] || continue
    if tm capture-pane -p -S -500 -t "$pane" | flatten | grep -qF -- "$want"; then
      seen_pane="$pane" seen_kind="$kind"; break
    fi
  done
  [ -n "$seen_pane" ] && break
  [ $(( ($(now_ms) - start) / 1000 )) -ge "$timeout" ] && break
  sleep 0.25
done
elapsed_ms=$(( $(now_ms) - start ))

if [ "$quiet" -eq 0 ]; then
  printf '{"agent":%s,"seen":%s,"pane":%s,"kind":%s,"ms":%s,"seconds":%s,"panes":{"agent":%s,"notice":%s},"sock":%s}\n' \
    "$(json_str "$agent")" \
    "$([ -n "$seen_pane" ] && echo true || echo false)" \
    "$(json_str "$seen_pane")" "$(json_str "$seen_kind")" "$elapsed_ms" "$(( elapsed_ms / 1000 ))" \
    "$(json_str "$ap")" "$(json_str "$np")" "$(json_str "$sock")"
fi
[ -n "$seen_pane" ]
