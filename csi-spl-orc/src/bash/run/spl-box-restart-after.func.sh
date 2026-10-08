#!/bin/bash
#------------------------------------------------------------------------------
# @description do_spl_box_restart_after - after the boot, once per pending
# @description restart (spl-box-restart-run.func.sh wrote <dir>/pending): the
# @description units the drain stopped started (never one the CPU budget
# @description parked), the active ones online, do_check_gh_runner; every run
# @description of the restart window with a failed or cancelled job on this
# @description box's runners re-run (gh run rerun --failed), logged in
# @description <dir>/<utc>.rerun; once the first agent window is up, ONE pass
# @description of every desk-reconcile line of this crontab (drill 2: the
# @description hub-run sidecar has no boot hook; its own safety refusal
# @description stays); then do_spl_box_restart_check.
# @param BOX_RESTART_AGENT_WAIT (optional) - after-boot seconds to wait for an agent window, default 900
# @param BOX_RESTART_RUNNER_WAIT (optional) - after-boot seconds to wait for the runners online, default 300
# @example ./run -a do_spl_box_restart_after
#------------------------------------------------------------------------------
# Test seam: BOX_RESTART_TMUX_CMD (tmux list-windows -a ...).
declare -F spl_brx_conf >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-run.func.sh"
declare -F do_spl_box_restart_check >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-check.func.sh"
declare -F do_check_gh_runner >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/check-gh-runner.func.sh"

SPL_BRX_AGENT_WIN_RE='^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'

do_spl_box_restart_after() {
  local root dir p utc rc=0
  root="${SPOOL_ROOT:-/var/spool-hub}"; dir="$root/dispatch/box-restart"; p="$dir/pending"
  [[ -f "$p" ]] || { do_log "INFO no pending restart in $dir: nothing to do"; return 0; }
  spl_brx_conf || return 1
  utc="$(spl_brx_pending_get "$p" utc)"
  do_log "INFO after the restart $utc"
  spl_brx_after_runners "$(spl_brx_pending_get "$p" drained)" || rc=1
  spl_brx_after_rerun "$(spl_brx_pending_get "$p" since)" "$dir/$utc.rerun" || rc=1
  spl_brx_after_desk || rc=1
  BOX_RESTART_BEFORE="$(spl_brx_pending_get "$p" snapshot)" do_spl_box_restart_check || rc=1
  printf 'after\t%s\trc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$p"
  mv "$p" "$dir/$utc.after"
  if (( rc == 0 )); then do_log "OK the restart $utc is done: runners, re-runs, desk and agents"
  else do_log "ERROR the restart $utc: a step above failed ($dir/$utc.after)"; fi
  return "$rc"
}

# The units the drain stopped started again unless the CPU budget parked
# them meanwhile (CPU_BUDGET_STATE_DIR/parked: stopped on purpose, never
# started here); every active runner online in the API; then
# do_check_gh_runner (service active or PARKED, Restart=always, rootless
# docker enabled and answering).
spl_brx_after_runners() {
  local drained="$1" units u org names="" end states off rc=0
  local parked="${CPU_BUDGET_STATE_DIR:-/var/tmp/gh-runner-cpu-budget}/parked"
  units="$(spl_brx_units)"
  [[ -n "$units" ]] || { do_log "OK no runner unit on this box"; return 0; }
  for u in $drained; do
    systemctl is-active -q "$u" 2>/dev/null && continue
    if grep -qxF "$u" "$parked" 2>/dev/null; then do_log "INFO $u is PARKED by the CPU budget: left stopped"; continue; fi
    if sudo -n systemctl start "$u"; then do_log "OK started $u"; else do_log "ERROR could not start $u"; rc=1; fi
  done
  for u in $units; do systemctl is-active -q "$u" 2>/dev/null && names+="$(spl_brx_unit_name "$u")"$'\n'; done
  org="$(spl_brx_unit_org "${units%%$'\n'*}")"
  end=$(( $(spl_brx_clock) + ${BOX_RESTART_RUNNER_WAIT:-300} ))
  while [[ -n "$names" ]]; do
    states="$(spl_brx_runner_states "$org")"
    off="$(awk -F'\t' 'NR == FNR {on[$1] = ($2 == "online"); next} $1 != "" && !on[$1] {printf "%s ", $1}' <(printf '%s\n' "$states") <(printf '%s' "$names"))"
    [[ -z "$off" ]] && { do_log "OK every active runner of this box is online: $(tr '\n' ' ' <<<"$names")"; break; }
    (( $(spl_brx_clock) >= end )) && { do_log "ERROR runner(s) not online: $off"; rc=1; break; }
    sleep "$SPL_BRX_POLL"
  done
  do_check_gh_runner || rc=1
  return "$rc"
}

# Re-run (--failed) every run updated since SINCE whose failed or cancelled
# job ran on one of this box's runners: what the restart killed. One line per
# run in LOG.
spl_brx_after_rerun() {
  local since="$1" log="$2" names id hit rc=0
  names="$(for u in $(spl_brx_units); do spl_brx_unit_name "$u"; done)"
  [[ -n "$names" && -n "$since" ]] || { do_log "OK no runner (or no start time): nothing to re-run"; return 0; }
  for id in $(gh run list -R "$SPL_BRX_REPO" --limit 100 --json databaseId,status,conclusion,updatedAt \
      --jq ".[] | select(.status == \"completed\" and (.conclusion == \"cancelled\" or .conclusion == \"failure\") and .updatedAt >= \"$since\") | .databaseId" 2>/dev/null); do
    hit="$(gh api "repos/$SPL_BRX_REPO/actions/runs/$id/jobs" --paginate \
      --jq '.jobs[] | select(.conclusion == "cancelled" or .conclusion == "failure") | .runner_name' 2>/dev/null | grep -Fxf <(printf '%s\n' "$names") | sed -n 1p)"
    [[ -n "$hit" ]] || continue
    if gh run rerun "$id" -R "$SPL_BRX_REPO" --failed >/dev/null 2>&1; then
      printf '%s\trerun\t%s\t%s\tok\n' "$(date -u +%FT%TZ)" "$id" "$hit" >> "$log"; do_log "OK re-ran run $id (a job on $hit)"
    else
      printf '%s\trerun\t%s\t%s\tfailed\n' "$(date -u +%FT%TZ)" "$id" "$hit" >> "$log"; do_log "ERROR gh run rerun $id failed"; rc=1
    fi
  done
  return "$rc"
}

# Once the first agent window is up: one pass of each desk-reconcile line of
# this crontab (its own safety refusal stays). No window in time: the
# 5-minute desk tick re-seats them, said so.
spl_brx_after_desk() {
  local end line cmd n=0 rc=0 app
  end=$(( $(spl_brx_clock) + ${BOX_RESTART_AGENT_WAIT:-900} ))
  until spl_brx_tmux_windows | grep -E "$SPL_BRX_AGENT_WIN_RE" >/dev/null; do
    (( $(spl_brx_clock) >= end )) && { do_log "WARN no agent window after ${BOX_RESTART_AGENT_WAIT:-900}s: no desk pass now, the desk-reconcile tick re-seats them"; return 0; }
    sleep "$SPL_BRX_POLL"
  done
  app="$(basename "${PROJ_PATH:-csi-spl-orc}")"; app="${app%-orc}"
  while IFS= read -r line; do
    cmd="$(awk '{$1 = $2 = $3 = $4 = $5 = ""; sub(/^ +/, ""); print}' <<<"$line")"
    n=$((n + 1))
    if bash -c "$cmd"; then do_log "OK desk-reconcile pass $n"; else do_log "ERROR desk-reconcile pass $n failed (its log has why)"; rc=1; fi
  done < <(crontab -l 2>/dev/null | grep -E "# $app:desk-reconcile(-[a-z]+)?\$" | grep -v '^[[:space:]]*#')
  (( n > 0 )) || do_log "WARN no desk-reconcile line in this crontab: no desk pass"
  return "$rc"
}

spl_brx_tmux_windows() {
  if [[ -n "${BOX_RESTART_TMUX_CMD:-}" ]]; then bash -c "$BOX_RESTART_TMUX_CMD"; return; fi
  tmux ${SPOOL_TMUX_SOCKET:+-S "$SPOOL_TMUX_SOCKET"} list-windows -a -F '#{window_name}' 2>/dev/null || true
}
