#!/bin/bash
#------------------------------------------------------------------------------
# @description The scheduled restart of THIS box (owner HUM-10, t1 1d936561:
# @description weekly, each box at its own slot; drill 2 2026-10-08 on the
# @description second box; "and we need to take into consideration of the
# @description CICD runs etc."). Three actions:
# @description do_spl_box_restart_run - the restart: (1) wait until no wf 20/30
# @description deploy is queued or running and no terraform process runs
# @description (the tf-runner container's), (2) drain this box's GitHub runners:
# @description each runner unit is stopped the moment the API reports it idle,
# @description so it takes no new job and no running job is killed, (3)
# @description do_spl_box_restart_prepare (snapshot + notes), (4) a grace for
# @description the agents to push, (5) <dir>/pending, then reboot. A step that
# @description is still busy after BOX_RESTART_WAIT DEFERS: the stopped runners
# @description are started again, nothing reboots, the next tick in the slot
# @description window retries. Dry run unless DRY_RUN=0: the read-only checks
# @description run and the plan is printed; nothing stops, writes or reboots.
# @description do_spl_box_restart_after - after the boot, once per pending
# @description restart: the units the drain stopped started (never one the CPU
# @description budget parked), the active ones online, do_check_gh_runner;
# @description every run of the restart window with
# @description a failed or cancelled job on this box's runners re-run (gh run
# @description rerun --failed), logged in <dir>/<utc>.rerun; once the first
# @description agent window is up, ONE pass of every desk-reconcile line of
# @description this crontab (drill 2: the hub-run sidecar has no boot hook;
# @description its own safety refusal stays); then do_spl_box_restart_check.
# @description do_spl_box_restart_tick - the cron entry (one line per box,
# @description do_spl_box_restart_install_cron): the after-boot pass when a
# @description pending restart has booted, else the restart when the slot is
# @description due, else nothing (and prints nothing).
# @param DRY_RUN (optional) - 1 (default) or 0; the tick always runs with 0
# @param BOX_RESTART_AT (optional) - "<cron weekday> <HH:MM> <tz>": the slot (tick: required)
# @param BOX_RESTART_WINDOW_MIN (optional) - minutes after the slot a deferred restart retries, default 180
# @param BOX_RESTART_WAIT (optional) - seconds to wait for deploys / the drain, default 1800
# @param BOX_RESTART_POLL (optional) - seconds between the waits' polls, default 30
# @param BOX_RESTART_GRACE (optional) - seconds between the notes and the reboot, default 300
# @param BOX_RESTART_REPO (optional) - <owner>/<repo>; default the checkout's (gh repo view)
# @param BOX_RESTART_DEPLOY_WORKFLOWS (optional) - default the wf 20 and wf 30 files
# @param BOX_RESTART_FROM (optional) - the notes' sender, default SPOOL_AGENT_ID, else c-001
# @param BOX_RESTART_AGENT_WAIT (optional) - after-boot seconds to wait for an agent window, default 900
# @param BOX_RESTART_RUNNER_WAIT (optional) - after-boot seconds to wait for the runners online, default 300
# @example ./run -a do_spl_box_restart_run
# @example DRY_RUN=0 ./run -a do_spl_box_restart_run
# @example ./run -a do_spl_box_restart_after
#------------------------------------------------------------------------------
# Test seams: BOX_RESTART_EPOCH (now), BOX_RESTART_REBOOT_CMD (sudo -n
# systemctl reboot), BOX_RESTART_TMUX_CMD (tmux list-windows -a ...), and
# the prepare's LEASE_PROC_ROOT / BOX_RESTART_PS_CMD / BOX_RESTART_SEND.
declare -F spl_brs_agents >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-prepare.func.sh"
declare -F do_spl_box_restart_check >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-check.func.sh"
declare -F do_check_gh_runner >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/check-gh-runner.func.sh"

SPL_BRX_AGENT_WIN_RE='^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)'

do_spl_box_restart_run() {
  local dry="${DRY_RUN:-1}" root dir utc snap why="" t0 rb
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_brx_conf || return 1
  root="${SPOOL_ROOT:-/var/spool-hub}"; dir="$root/dispatch/box-restart"
  utc="${BOX_RESTART_NOW:-$(date -u -d "@$(spl_brx_now)" +%Y%m%dT%H%M%SZ)}"; snap="$dir/$utc.before"
  SPL_BRX_STOPPED=(); t0="$(date -u -d "@$(spl_brx_now)" +%Y-%m-%dT%H:%M:%SZ)"
  [[ "$dry" == 1 ]] && do_log "INFO DRY RUN: the checks run, nothing is stopped, written or rebooted (DRY_RUN=0 does it)"
  if ! spl_brx_wait_quiet "$dry"; then spl_brx_defer "$dry" "$dir" "$utc" "a deploy or terraform run is still in flight after ${SPL_BRX_WAIT}s"; return 0; fi
  if ! spl_brx_drain "$dry"; then spl_brx_defer "$dry" "$dir" "$utc" "a runner is still busy after ${SPL_BRX_WAIT}s"; return 0; fi
  [[ "$dry" == 0 ]] && why="$(spl_brx_inflight)"
  if [[ -n "$why" ]]; then spl_brx_defer "$dry" "$dir" "$utc" "started during the drain: ${why//$'\n'/; }"; return 0; fi
  DRY_RUN="$dry" BOX_RESTART_NOW="$utc" BOX_RESTART_FROM="$SPL_BRX_FROM" do_spl_box_restart_prepare ||
    do_log "WARN do_spl_box_restart_prepare reported an error (above); the restart goes on when its snapshot is there"
  if [[ "$dry" == 1 ]]; then
    do_log "INFO PLAN sleep ${SPL_BRX_GRACE}s (the agents push), write $dir/pending, then: $(spl_brx_reboot_cmd)"
    do_log "INFO PLAN after the boot (the next tick): do_spl_box_restart_after"
    return 0
  fi
  [[ -f "$snap" ]] || { spl_brx_runners_start; do_log "ERROR no snapshot $snap: no reboot (the runners are started again)"; return 1; }
  sleep "$SPL_BRX_GRACE"
  # the CPU budget cron may have started a parked runner during the grace
  if ! spl_brx_drain 0; then spl_brx_defer 0 "$dir" "$utc" "a runner took a job during the grace and is still busy after ${SPL_BRX_WAIT}s"; return 0; fi
  spl_brx_pending_write "$dir" "$utc" "$snap" "$t0" || { spl_brx_runners_start; return 1; }
  do_log "OK REBOOT now: $(spl_brx_reboot_cmd)"
  read -ra rb <<<"$(spl_brx_reboot_cmd)"
  if ! "${rb[@]}"; then
    rm -f "$dir/pending"; spl_brx_runners_start
    do_log "ERROR the reboot command failed: nothing rebooted, the runners are started again"; return 1
  fi
}

# SPL_BRX_REPO / _WAIT / _POLL / _GRACE / _FROM / _WFS, each checked.
spl_brx_conf() {
  local k v
  SPL_BRX_WAIT="${BOX_RESTART_WAIT:-1800}" SPL_BRX_POLL="${BOX_RESTART_POLL:-30}" SPL_BRX_GRACE="${BOX_RESTART_GRACE:-300}"
  for k in SPL_BRX_WAIT SPL_BRX_POLL SPL_BRX_GRACE; do
    v="${!k}"; [[ "$v" =~ ^[0-9]+$ ]] || { do_log "FATAL ${k/SPL_BRX_/BOX_RESTART_} must be a number of seconds, got: '$v'"; return 1; }
  done
  SPL_BRX_FROM="${BOX_RESTART_FROM:-${SPOOL_AGENT_ID:-c-001}}"
  SPL_BRX_WFS="${BOX_RESTART_DEPLOY_WORKFLOWS:-20_hub-build-deploy.yml 30_wui-build-deploy.yml}"
  SPL_BRX_REPO="${BOX_RESTART_REPO:-$(cd "${APP_PATH:-.}" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
  [[ "$SPL_BRX_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    { do_log "FATAL no <owner>/<repo>: set BOX_RESTART_REPO (gh repo view gave '${SPL_BRX_REPO}')"; return 1; }
}

spl_brx_now() { echo "${BOX_RESTART_EPOCH:-$(date +%s)}"; }
# The waits' deadlines run on the real clock, never the seam.
spl_brx_clock() { date +%s; }
spl_brx_reboot_cmd() { echo "${BOX_RESTART_REBOOT_CMD:-sudo -n systemctl reboot}"; }

# What blocks a restart, one line each, nothing when quiet: a queued or
# running deploy (wf 20/30), a terraform process. A gh error counts as busy.
spl_brx_inflight() {
  local wf st ids
  for wf in $SPL_BRX_WFS; do
    for st in in_progress queued; do
      if ! ids="$(gh run list -R "$SPL_BRX_REPO" --workflow "$wf" --status "$st" --json databaseId --jq '.[].databaseId' 2>/dev/null)"; then
        echo "deploy $wf: gh run list failed (counted as busy)"; continue
      fi
      [[ -n "$ids" ]] && echo "deploy $wf $st: run(s) ${ids//$'\n'/ }"
    done
  done
  spl_brs_ps | awk '$3 == "terraform" {print "terraform pid " $1}'
  return 0
}

# Wait until spl_brx_inflight is empty, BOX_RESTART_WAIT at most (dry: report once).
spl_brx_wait_quiet() {
  local dry="$1" why end
  end=$(( $(spl_brx_clock) + SPL_BRX_WAIT ))
  while :; do
    why="$(spl_brx_inflight)"
    [[ -z "$why" ]] && { do_log "OK no deploy (${SPL_BRX_WFS}) and no terraform run in flight"; return 0; }
    if [[ "$dry" == 1 ]]; then do_log "INFO PLAN wait up to ${SPL_BRX_WAIT}s, then DEFER, for: ${why//$'\n'/; }"; return 0; fi
    (( $(spl_brx_clock) >= end )) && { do_log "WARN still in flight: ${why//$'\n'/; }"; return 1; }
    do_log "INFO waiting: ${why//$'\n'/; }"
    sleep "$SPL_BRX_POLL"
  done
}

# The runner units of this box (actions.runner.<org>.<name>.service).
spl_brx_units() {
  systemctl list-units --type=service --all --no-legend --plain 2>/dev/null |
    awk '$1 ~ /^actions\.runner\..+\.service$/ {print $1}' | LC_ALL=C sort -u
}
# spl_brx_unit_org UNIT / spl_brx_unit_name UNIT
spl_brx_unit_org() { local x="${1#actions.runner.}"; echo "${x%%.*}"; }
spl_brx_unit_name() { local x="${1#actions.runner.}"; x="${x#*.}"; echo "${x%.service}"; }
# "<name>\t<status>\t<busy>" per runner of ORG, from the API.
spl_brx_runner_states() {
  gh api "orgs/$1/actions/runners" --paginate --jq '.runners[] | [.name, .status, (.busy | tostring)] | @tsv' 2>/dev/null || true
}

# Stop each active runner unit once the API reports it idle (no new job, no
# killed job); 1 when one is still busy after BOX_RESTART_WAIT. The stopped
# units go into SPL_BRX_STOPPED (spl_brx_runners_start takes them back).
spl_brx_drain() {
  local dry="$1" units u name states left end busy
  units="$(spl_brx_units)"
  [[ -n "$units" ]] || { do_log "OK no runner unit on this box: nothing to drain"; return 0; }
  if [[ "$dry" == 1 ]]; then
    for u in $units; do do_log "INFO PLAN drain $u: stop it once idle (up to ${SPL_BRX_WAIT}s, then DEFER)"; done
    return 0
  fi
  end=$(( $(spl_brx_clock) + SPL_BRX_WAIT ))
  while :; do
    left=0; states="$(spl_brx_runner_states "$(spl_brx_unit_org "${units%%$'\n'*}")")"
    for u in $units; do
      systemctl is-active -q "$u" 2>/dev/null || continue
      name="$(spl_brx_unit_name "$u")"
      busy="$(awk -F'\t' -v n="$name" '$1 == n {print $3}' <<<"$states")"
      if [[ "$busy" == false ]] && sudo -n systemctl stop "$u"; then
        SPL_BRX_STOPPED+=("$u"); do_log "OK drained $name: idle, its unit is stopped"
      else left=$((left + 1)); fi
    done
    (( left == 0 )) && { do_log "OK every runner of this box is drained"; return 0; }
    (( $(spl_brx_clock) >= end )) && return 1
    do_log "INFO $left runner(s) still busy"
    sleep "$SPL_BRX_POLL"
  done
}

# Start again the units the drain stopped.
spl_brx_runners_start() {
  local u
  for u in "${SPL_BRX_STOPPED[@]}"; do
    if sudo -n systemctl start "$u"; then do_log "OK started $u again"; else do_log "ERROR could not start $u"; fi
  done
  SPL_BRX_STOPPED=()
}

# Defer: the runners back, the reason logged (and kept in <utc>.deferred).
spl_brx_defer() {
  local dry="$1" dir="$2" utc="$3" why="$4"
  spl_brx_runners_start
  do_log "WARN DEFER the restart: $why. Nothing rebooted; the next tick in the slot window retries."
  [[ "$dry" == 0 ]] && mkdir -p "$dir" && printf '%s\n' "$why" > "$dir/$utc.deferred"
  return 0
}

# <dir>/pending (key\tvalue): utc, since (the drain's start, ISO), snapshot,
# btime, the week it counts for, the units the drain stopped; and <dir>/last-week, so the slot window does not reboot twice.
spl_brx_pending_write() {
  local dir="$1" utc="$2" snap="$3" since="$4" week
  week="$(spl_brx_slot_week)"
  { printf 'utc\t%s\nsince\t%s\nsnapshot\t%s\nbtime\t%s\nweek\t%s\ndrained\t%s\n' "$utc" \
      "$since" "$snap" "$(spl_brs_btime)" "$week" "${SPL_BRX_STOPPED[*]}" > "$dir/pending.tmp" &&
      mv "$dir/pending.tmp" "$dir/pending" && printf '%s\n' "$week" > "$dir/last-week"; } ||
    { do_log "ERROR could not write $dir/pending: no reboot"; return 1; }
}
spl_brx_pending_get() { awk -F'\t' -v k="$2" '$1 == k {print $2; exit}' "$1" 2>/dev/null; }

# ---- the slot ------------------------------------------------------------------

# Parse BOX_RESTART_AT into SPL_BRX_DOW / _HM / _TZ.
spl_brx_slot_parse() {
  read -r SPL_BRX_DOW SPL_BRX_HM SPL_BRX_TZ <<<"${BOX_RESTART_AT:-}"
  [[ "$SPL_BRX_DOW" =~ ^[0-6]$ && "$SPL_BRX_HM" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ && -n "$SPL_BRX_TZ" ]] ||
    { do_log "FATAL BOX_RESTART_AT must be '<weekday 0-6> <HH:MM> <tz>', got: '${BOX_RESTART_AT:-}'"; return 1; }
  [[ -e "/usr/share/zoneinfo/$SPL_BRX_TZ" ]] || { do_log "FATAL unknown time zone: '$SPL_BRX_TZ'"; return 1; }
}
spl_brx_slot_week() { TZ="${SPL_BRX_TZ:-UTC}" date -d "@$(spl_brx_now)" +%G-W%V; }

# 0 when now (in the slot's zone) is on the slot's weekday, within
# BOX_RESTART_WINDOW_MIN after its time, and this week has not restarted yet.
spl_brx_slot_due() {
  local dir="$1" dow hm now_min slot_min win="${BOX_RESTART_WINDOW_MIN:-180}"
  [[ "$win" =~ ^[0-9]+$ ]] || { do_log "FATAL BOX_RESTART_WINDOW_MIN must be a number of minutes"; return 1; }
  read -r dow hm <<<"$(TZ="$SPL_BRX_TZ" date -d "@$(spl_brx_now)" '+%w %H:%M')"
  [[ "$dow" == "$SPL_BRX_DOW" ]] || return 1
  now_min=$((10#${hm%:*} * 60 + 10#${hm#*:})); slot_min=$((10#${SPL_BRX_HM%:*} * 60 + 10#${SPL_BRX_HM#*:}))
  (( now_min >= slot_min && now_min < slot_min + win )) || return 1
  [[ "$(cat "$dir/last-week" 2>/dev/null)" != "$(spl_brx_slot_week)" ]]
}

# ---- the tick (cron) -------------------------------------------------------------

do_spl_box_restart_tick() {
  local root dir rc=0 bt0 since
  root="${SPOOL_ROOT:-/var/spool-hub}"; dir="$root/dispatch/box-restart"
  spl_brx_slot_parse || return 1
  mkdir -p "$dir" || return 1
  exec 8>"$dir/.lock"
  flock -n 8 || { exec 8>&-; return 0; }
  if [[ -f "$dir/pending" ]]; then
    bt0="$(spl_brx_pending_get "$dir/pending" btime)"
    if [[ "$(spl_brs_btime)" != "$bt0" ]]; then
      do_spl_box_restart_after || rc=1
    else
      since="$(date -d "$(spl_brx_pending_get "$dir/pending" since)" +%s 2>/dev/null || echo 0)"
      if (( $(spl_brx_now) - since > 900 )); then
        do_log "ERROR $dir/pending is 15 min old and the box has not rebooted: dropped; start the runners by hand if the drain stopped them (systemctl start 'actions.runner.*')"
        mv "$dir/pending" "$dir/$(spl_brx_pending_get "$dir/pending" utc).noboot"; rc=1
      fi
    fi
  elif spl_brx_slot_due "$dir"; then
    do_log "INFO the slot ${BOX_RESTART_AT} is due: the scheduled restart"
    DRY_RUN=0 do_spl_box_restart_run || rc=1
  fi
  exec 8>&-
  return "$rc"
}

# ---- after the boot --------------------------------------------------------------

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
