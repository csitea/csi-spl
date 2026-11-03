#!/bin/bash
#------------------------------------------------------------------------------
# @description An agent's full-output log follows its rotations (spec 160
# @description section 3.9, SPL-4718): for each agent with a full-output
# @description allow entry in cnf env.box.file_streams.allow (a path ending
# @description in /<id>.log), finds the agent's current pane, the newest
# @description registry.tsv row of the id whose pane is live in a window
# @description named for the id, and when its #{pane_pipe} is 0 attaches
# @description `tmux pipe-pane -o` through src/bash/scripts/
# @description agent-log-strip-ansi.pl, appending (>>) to that path. A pane
# @description already piped is left alone, and -o never opens a second pipe;
# @description the agent's pokes side pane (spool-notice-pane) is never piped.
# @description A rotation starts a new pane with no pipe; the minute cron row
# @description agent-steps-log runs this first, so the log grows again within
# @description one tick.
# @param AGENT_LOG_PIPE_CNF (optional) - default csi-spl-cnf/csi-spl/all.env.yaml
# @param SPOOL_ROOT (optional) - its registry.tsv; default /var/spool-hub
# @param SPOOL_TMUX_SOCKET (optional) - default /tmp/tmux-<uid of
# @param   SPOOL_BOX_USER, else the caller>/default
# @param AGENT_LOG_PIPE_TMUX (optional) - the tmux binary; default tmux on PATH
# @example ./run -a do_spl_agent_log_pipe
#------------------------------------------------------------------------------

# Exit: 0 every log piped or nothing to pipe (an agent with no live pane is
# skipped), 1 a setup refusal, 2 an attach that did not take.
do_spl_agent_log_pipe() {
  local orc cnf pl reg sock panes path id pane rc=0
  orc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  cnf="${AGENT_LOG_PIPE_CNF:-$orc/../csi-spl-cnf/csi-spl/all.env.yaml}"
  pl="$orc/src/bash/scripts/agent-log-strip-ansi.pl"
  reg="${SPOOL_ROOT:-/var/spool-hub}/registry.tsv"
  sock="${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "${SPOOL_BOX_USER:-$(id -un)}" 2>/dev/null || id -u)/default}"
  [[ -r "$cnf" ]] || { echo "FATAL agent-log-pipe: no cnf $cnf"; return 1; }
  [[ -r "$pl" ]] || { echo "FATAL agent-log-pipe: no filter $pl"; return 1; }
  [[ -r "$reg" ]] || { echo "FATAL agent-log-pipe: no registry $reg"; return 1; }
  # <pane> <pipe> <side|main> <window name>: side = the pokes notice pane
  panes="$("${AGENT_LOG_PIPE_TMUX:-tmux}" -S "$sock" list-panes -a -F '#{pane_id} #{pane_pipe} #{?#{m:*spool-notice-pane*,#{pane_start_command}},side,main} #{window_name}' 2>/dev/null)"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" != *"'"* ]] || { echo "FATAL agent-log-pipe: quote in path $path"; rc=1; continue; }
    id="${path##*/}"; id="${id%.log}"
    pane="$(spl_agent_log_pipe_pane "$reg" "$id" "$panes")"
    [[ -n "$pane" ]] || { echo "SKIP agent-log-pipe: $id has no live pane"; continue; }
    spl_agent_log_pipe_one "$sock" "$pl" "$path" "$id" "$pane" "$panes" || rc=2
  done < <(spl_agent_log_pipe_paths "$cnf")
  return "$rc"
}

# spl_agent_log_pipe_paths <cnf>: the full-output log paths, one per line:
# each allow path whose last segment is <agent id>.log.
spl_agent_log_pipe_paths() {
  yq -r '.env.box.file_streams.allow // [] | .[].path' "$1" 2>/dev/null |
    grep -E '/[acgmq]-[0-9]{3}\.log$' || true
}

# spl_agent_log_pipe_pane <registry> <id> <panes>: the id's current pane, the
# newest registry row (by its start stamp) whose pane is in <panes> and sits
# in a window named for the id and is not its pokes side pane (a pane id is
# reused after a tmux restart, so an old row alone does not prove the pane
# is the agent's harness).
spl_agent_log_pipe_pane() {
  local reg="$1" id="$2" panes="$3" p w
  while read -r p; do
    w="$(awk -v p="$p" '$1 == p && $3 == "main" { $1 = ""; $2 = ""; $3 = ""; print; exit }' <<<"$panes")"
    [[ " $w " =~ [\ :]"$id"[@\ ] ]] && { printf '%s' "$p"; return 0; }
  done < <(awk -F'\t' -v id="$id" '$1 == id && $3 ~ /^%[0-9]+$/ { print $5 "\t" $3 }' "$reg" | sort -r | cut -f2)
  return 0
}

# spl_agent_log_pipe_one <sock> <pl> <log> <id> <pane> <panes>: attach the
# pipe when the pane has none, then read #{pane_pipe} back.
spl_agent_log_pipe_one() {
  local sock="$1" pl="$2" log="$3" id="$4" pane="$5" panes="$6" now
  [[ "$(awk -v p="$pane" '$1 == p { print $2; exit }' <<<"$panes")" == 1 ]] && return 0
  [[ -e "$log" ]] || { : >>"$log" && chmod 0644 "$log"; } ||
    { echo "FATAL agent-log-pipe: $(id -un) cannot write $log"; return 2; }
  "${AGENT_LOG_PIPE_TMUX:-tmux}" -S "$sock" pipe-pane -o -t "$pane" "exec perl '$pl' >> '$log'"
  now="$("${AGENT_LOG_PIPE_TMUX:-tmux}" -S "$sock" display-message -p -t "$pane" '#{pane_pipe}' 2>/dev/null)"
  [[ "$now" == 1 ]] || { echo "ERROR agent-log-pipe: $id pane $pane: pipe-pane did not take (pane_pipe=$now)"; return 2; }
  echo "OK agent-log-pipe: $id pane $pane piped to $log"
}
