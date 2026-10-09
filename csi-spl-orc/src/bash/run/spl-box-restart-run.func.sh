#!/bin/bash
#------------------------------------------------------------------------------
# @description The scheduled restart of THIS box (owner HUM-10, t1 1d936561:
# @description weekly, each box at its own slot; drill 2 2026-10-08 on the
# @description second box; "and we need to take into consideration of the
# @description CICD runs etc."). Three actions, one file each (the ./run
# @description loader maps kebab-case.func.sh to ONE do_snake_case): this one,
# @description spl-box-restart-tick.func.sh and spl-box-restart-after.func.sh.
# @description This file also keeps the spl_brx_* helpers the other two share.
# @description do_spl_box_restart_run - the restart: (1) wait until no wf 20/30
# @description deploy is queued or running and no terraform process runs
# @description (the tf-runner container's), (2) drain this box's GitHub runners:
# @description first their custom labels (spool-ci) come off, so no queued job
# @description matches them any more, then each runner unit is stopped the
# @description moment the API reports it idle: no running job is killed, and
# @description a busy runner on a busy trunk ends its job instead of taking the
# @description next one (drills 6 and 7, 2026-10-09, deferred on that), (3)
# @description do_spl_box_restart_prepare (snapshot + notes), (4) a grace for
# @description the agents to push, (5) <dir>/pending, then reboot. A step that
# @description is still busy after BOX_RESTART_WAIT DEFERS: the stopped runners
# @description are started again and get their labels back, nothing reboots, the next tick in the slot
# @description window retries. A shutdown BLOCK inhibitor (a desktop box: the
# @description GNOME session holds one) DEFERS too, before the notes and again
# @description right before the reboot: systemd 257 logind obeys it even for
# @description root and answers "Access denied" (drill 7, 2026-10-09). cnf
# @description env.box.restart.inhibitors: respect (default) defers, ignore
# @description reboots past it (systemctl reboot --check-inhibitors=no).
# @description <dir>/last-week is written only once the reboot command has
# @description returned 0. Dry run unless DRY_RUN=0: the read-only checks
# @description run and the plan is printed; nothing stops, writes or reboots.
# @param DRY_RUN (optional) - 1 (default) or 0; the tick always runs with 0
# @param BOX_RESTART_WAIT (optional) - seconds to wait for deploys / the drain, default 1800
# @param BOX_RESTART_POLL (optional) - seconds between the waits' polls, default 30
# @param BOX_RESTART_GRACE (optional) - seconds between the notes and the reboot, default 300
# @param BOX_RESTART_REPO (optional) - <owner>/<repo>; default cnf github_repository, else gh repo view
# @param BOX_RESTART_INHIBITORS (optional) - respect | ignore; default cnf env.box.restart.inhibitors, else respect
# @param BOX_RESTART_CNF (optional) - default <checkout>/<org>-<app>-cnf/<org>-<app>/all.env.yaml
# @param BOX_RESTART_GH_TOKEN_FILE (optional) - read into GH_TOKEN when gh is not logged in; default $HOME/.github/token
# @param BOX_RESTART_DEPLOY_WORKFLOWS (optional) - default the wf 20 and wf 30 files
# @param BOX_RESTART_FROM (optional) - the notes' sender, default SPOOL_AGENT_ID, else c-001
# @example ./run -a do_spl_box_restart_run
# @example DRY_RUN=0 ./run -a do_spl_box_restart_run
#------------------------------------------------------------------------------
# Test seams: BOX_RESTART_EPOCH (now), BOX_RESTART_REBOOT_CMD (sudo -n
# systemctl reboot), BOX_RESTART_INHIBITORS_CMD (busctl ListInhibitors), BOX_RESTART_CGROUP_ROOT (/sys/fs/cgroup), and the prepare's LEASE_PROC_ROOT / BOX_RESTART_PS_CMD /
# BOX_RESTART_SEND.
declare -F spl_brs_agents >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-box-restart-prepare.func.sh"

do_spl_box_restart_run() {
  local dry="${DRY_RUN:-1}" root dir utc snap why="" t0 rb
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_brx_conf || return 1
  root="${SPOOL_ROOT:-/var/spool-hub}"; dir="$root/dispatch/box-restart"
  utc="${BOX_RESTART_NOW:-$(date -u -d "@$(spl_brx_now)" +%Y%m%dT%H%M%SZ)}"; snap="$dir/$utc.before"
  SPL_BRX_STOPPED=(); SPL_BRX_DIR="$dir"; SPL_BRX_UNLABELED=0; t0="$(date -u -d "@$(spl_brx_now)" +%Y-%m-%dT%H:%M:%SZ)"
  [[ "$dry" == 1 ]] && do_log "INFO DRY RUN: the checks run, nothing is stopped, written or rebooted (DRY_RUN=0 does it)"
  why="$(spl_brx_inhibited)"
  if [[ -n "$why" && "$dry" == 0 ]]; then spl_brx_defer 0 "$dir" "$utc" "$why"; return 0; fi
  [[ -n "$why" ]] && do_log "INFO PLAN DEFER here, before the drain and the notes: $why"
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
  why="$(spl_brx_inhibited)"
  if [[ -n "$why" ]]; then spl_brx_defer 0 "$dir" "$utc" "$why (taken during the grace)"; return 0; fi
  spl_brx_pending_write "$dir" "$utc" "$snap" "$t0" || { spl_brx_runners_start; return 1; }
  do_log "OK REBOOT now: $(spl_brx_reboot_cmd)"
  read -ra rb <<<"$(spl_brx_reboot_cmd)"
  if ! "${rb[@]}"; then
    rm -f "$dir/pending"; spl_brx_runners_start
    do_log "ERROR the reboot command failed: nothing rebooted, the runners are started again, last-week not written (the slot window retries)"; return 1
  fi
  # the reboot has started: the slot window does not reboot twice
  spl_brx_pending_get "$dir/pending" week > "$dir/last-week"
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
  spl_brx_gh_auth
  SPL_BRX_REPO="${BOX_RESTART_REPO:-$(spl_brx_cnf_get '.. | select(type == "!!map" and has("github_repository")) | .github_repository')}"
  [[ -n "$SPL_BRX_REPO" ]] ||
    SPL_BRX_REPO="$(cd "${APP_PATH:-.}" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  [[ "$SPL_BRX_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    { do_log "FATAL no <owner>/<repo>: set BOX_RESTART_REPO (cnf github_repository / gh repo view gave '${SPL_BRX_REPO}')"; return 1; }
  SPL_BRX_INHIBIT="${BOX_RESTART_INHIBITORS:-$(spl_brx_cnf_get '.env.box.restart.inhibitors // ""')}"
  SPL_BRX_INHIBIT="${SPL_BRX_INHIBIT:-respect}"
  [[ "$SPL_BRX_INHIBIT" == respect || "$SPL_BRX_INHIBIT" == ignore ]] ||
    { do_log "FATAL BOX_RESTART_INHIBITORS (cnf env.box.restart.inhibitors) must be respect or ignore, got: '$SPL_BRX_INHIBIT'"; return 1; }
}

# spl_brx_cnf_get EXPR: one value of the cnf all.env.yaml (yq), nothing when
# there is no cnf or no yq.
spl_brx_cnf_get() {
  local oa="${SPL_ORG_APP:-$(basename "${PROJ_PATH:-x-orc}")}" cnf v
  oa="${oa%-orc}"; cnf="${BOX_RESTART_CNF:-${APP_PATH:-.}/$oa-cnf/$oa/all.env.yaml}"
  [[ -f "$cnf" ]] && command -v yq >/dev/null 2>&1 || return 0
  v="$(yq -r "$1" "$cnf" 2>/dev/null)"; v="${v%%$'\n'*}"
  [[ "$v" == null ]] || echo "$v"
  return 0
}

# A cron job (and an agent on a box with no gh login) has no gh login of its
# own: the box user's token file is read into GH_TOKEN (never printed).
spl_brx_gh_auth() {
  local f="${BOX_RESTART_GH_TOKEN_FILE:-$HOME/.github/token}"
  [[ -n "${GH_TOKEN:-}" ]] && return 0
  gh auth status >/dev/null 2>&1 && return 0
  [[ -r "$f" ]] && { GH_TOKEN="$(cat "$f")"; export GH_TOKEN; }
  return 0
}

spl_brx_now() { echo "${BOX_RESTART_EPOCH:-$(date +%s)}"; }
# The waits' deadlines run on the real clock, never the seam.
spl_brx_clock() { date +%s; }
spl_brx_reboot_cmd() {
  local c="${BOX_RESTART_REBOOT_CMD:-sudo -n systemctl reboot}"
  [[ "${SPL_BRX_INHIBIT:-respect}" == ignore ]] && c+=" --check-inhibitors=no"
  echo "$c"
}

# The shutdown BLOCK inhibitor locks, one "<who> (<why>; uid <u> pid <p>)"
# per line (logind ListInhibitors). Unreadable logind: nothing.
spl_brx_inhibitors() {
  local cmd="${BOX_RESTART_INHIBITORS_CMD:-busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ListInhibitors}"
  $cmd 2>/dev/null | jq -r '.data[0][] | select(.[3] == "block" and (.[0] | split(":") | index("shutdown")))
    | "\(.[1]) (\(.[2]); uid \(.[4]) pid \(.[5]))"' 2>/dev/null
  return 0
}

# Why the restart must wait for the inhibitors, nothing when it need not:
# with SPL_BRX_INHIBIT=respect a shutdown block lock defers (logind refuses
# the reboot: "Access denied"); with ignore it is logged and reboots past it.
spl_brx_inhibited() {
  local locks
  locks="$(spl_brx_inhibitors)"
  [[ -n "$locks" ]] || return 0
  if [[ "$SPL_BRX_INHIBIT" == ignore ]]; then
    do_log "WARN a shutdown block inhibitor is held (${locks//$'\n'/; }): cnf env.box.restart.inhibitors=ignore reboots past it" >&2
    return 0
  fi
  echo "a shutdown block inhibitor is held: ${locks//$'\n'/; } (cnf env.box.restart.inhibitors=respect; logind refuses the reboot; end that session or set ignore for this box)"
}

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
# "<name>\t<status>\t<busy>\t<id>\t<custom labels, comma-joined>" per
# runner of ORG, from the API.
spl_brx_runner_states() {
  gh api "orgs/$1/actions/runners" --paginate \
    --jq '.runners[] | [.name, .status, (.busy | tostring), (.id | tostring), ([.labels[] | select(.type == "custom") | .name] | join(","))] | @tsv' 2>/dev/null || true
}

# Take the custom labels (spool-ci) off every active runner unit of UNITS
# (STATES = spl_brx_runner_states): no queued job matches it any more, so a
# busy runner ends its job and stays idle, and nothing is killed. Why labels:
# a stop (the runner service, SIGTERM/SIGINT to Runner.Listener) cancels the running job,
# a once-mode needs a listener restart, and the API has no "offline" switch;
# DELETE .../labels removes only the custom ones, PUT sets them back. One row
# "<org>\t<name>\t<id>\t<labels>" per runner in <SPL_BRX_DIR>/unlabeled,
# written BEFORE the delete and kept across the reboot (the after-boot pass
# restores it); a runner already there keeps its first row.
spl_brx_unlabel() {
  local units="$1" states="$2" f="$SPL_BRX_DIR/unlabeled" u org name id labels
  for u in $units; do
    systemctl is-active -q "$u" 2>/dev/null || continue
    org="$(spl_brx_unit_org "$u")"; name="$(spl_brx_unit_name "$u")"
    IFS=$'\t' read -r id labels < <(awk -F'\t' -v n="$name" '$1 == n {print $4 "\t" $5; exit}' <<<"$states")
    [[ -n "$labels" ]] || continue
    [[ "$id" =~ ^[0-9]+$ ]] || { do_log "WARN $name: no runner id from the API, its labels ($labels) stay"; continue; }
    mkdir -p "$SPL_BRX_DIR" || return 1
    awk -F'\t' -v n="$name" '$2 == n {f = 1} END {exit !f}' "$f" 2>/dev/null ||
      printf '%s\t%s\t%s\t%s\n' "$org" "$name" "$id" "$labels" >>"$f" || return 1
    SPL_BRX_UNLABELED=1
    if gh api -X DELETE "orgs/$org/actions/runners/$id/labels" >/dev/null 2>&1; then
      do_log "OK $name: labels $labels off, it takes no new job"
    else do_log "ERROR $name: could not take its labels ($labels) off: it may take a new job"; fi
  done
}

# Put back the labels spl_brx_unlabel took off (DIR/unlabeled); the file
# goes once every row is back, a failed row stays for the next pass.
spl_brx_labels_restore() {
  local f="$1/unlabeled" org name id labels keep="" rc=0
  [[ -s "$f" ]] || return 0
  while IFS=$'\t' read -r org name id labels; do
    [[ -n "$id" ]] || continue
    if jq -cn --arg l "$labels" '{labels: ($l | split(","))}' |
        gh api -X PUT "orgs/$org/actions/runners/$id/labels" --input - >/dev/null 2>&1; then
      do_log "OK $name: labels $labels back"
    else
      keep+="$org"$'\t'"$name"$'\t'"$id"$'\t'"$labels"$'\n'; rc=1
      do_log "ERROR $name: could not put its labels ($labels) back (kept in $f)"
    fi
  done <"$f"
  if [[ -n "$keep" ]]; then printf '%s' "$keep" >"$f"; else rm -f "$f"; fi
  return "$rc"
}

# 0 when a Runner.Worker (a job) runs in UNIT's cgroup. The local truth, read
# right before the stop: the API's busy flag lags a job assignment, and a
# stop in that window cancels the job. Unreadable cgroup: 1 (the API decides).
spl_brx_unit_working() {
  local cg p
  cg="$(systemctl show -p ControlGroup --value "$1" 2>/dev/null)"
  [[ -n "$cg" ]] || return 1
  for p in $(cat "${BOX_RESTART_CGROUP_ROOT:-/sys/fs/cgroup}$cg/cgroup.procs" 2>/dev/null); do
    [[ "$(cat "${LEASE_PROC_ROOT:-/proc}/$p/comm" 2>/dev/null)" == Runner.Worker ]] && return 0
  done
  return 1
}

# Take every active runner's labels off (spl_brx_unlabel, each poll: a unit
# the CPU budget starts meanwhile too), then stop each active runner unit
# once the API reports it idle and no Runner.Worker runs in it (no new job,
# no killed job); 1 when one is still busy after BOX_RESTART_WAIT. The
# stopped units go into SPL_BRX_STOPPED (spl_brx_runners_start takes them
# back, and the labels).
spl_brx_drain() {
  local dry="$1" units u name states left end busy
  units="$(spl_brx_units)"
  [[ -n "$units" ]] || { do_log "OK no runner unit on this box: nothing to drain"; return 0; }
  if [[ "$dry" == 1 ]]; then
    for u in $units; do do_log "INFO PLAN drain $u: take its custom labels off (no new job), stop it once idle (up to ${SPL_BRX_WAIT}s, then DEFER)"; done
    return 0
  fi
  end=$(( $(spl_brx_clock) + SPL_BRX_WAIT ))
  while :; do
    left=0; states="$(spl_brx_runner_states "$(spl_brx_unit_org "${units%%$'\n'*}")")"
    spl_brx_unlabel "$units" "$states"
    for u in $units; do
      systemctl is-active -q "$u" 2>/dev/null || continue
      name="$(spl_brx_unit_name "$u")"
      busy="$(awk -F'\t' -v n="$name" '$1 == n {print $3}' <<<"$states")"
      if [[ "$busy" == false ]] && spl_brx_unit_working "$u"; then
        do_log "INFO $name: the API says idle, but a Runner.Worker runs in its unit (a job just taken): not stopped"
        left=$((left + 1))
      elif [[ "$busy" == false ]] && sudo -n systemctl stop "$u"; then
        SPL_BRX_STOPPED+=("$u"); do_log "OK drained $name: idle, its unit is stopped"
      else left=$((left + 1)); fi
    done
    (( left == 0 )) && { do_log "OK every runner of this box is drained"; return 0; }
    (( $(spl_brx_clock) >= end )) && return 1
    do_log "INFO $left runner(s) still busy"
    sleep "$SPL_BRX_POLL"
  done
}

# Start again the units the drain stopped; the labels it took off go back.
spl_brx_runners_start() {
  local u
  for u in "${SPL_BRX_STOPPED[@]}"; do
    if sudo -n systemctl start "$u"; then do_log "OK started $u again"; else do_log "ERROR could not start $u"; fi
  done
  SPL_BRX_STOPPED=()
  [[ "${SPL_BRX_UNLABELED:-0}" == 1 ]] && { spl_brx_labels_restore "$SPL_BRX_DIR"; SPL_BRX_UNLABELED=0; }
  return 0
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
# btime, the week it counts for, the units the drain stopped. <dir>/last-week
# (the slot window does not reboot twice) is written only once the reboot
# command returned 0, and again by the tick once the box has booted.
spl_brx_pending_write() {
  local dir="$1" utc="$2" snap="$3" since="$4" week
  week="$(spl_brx_slot_week)"
  { printf 'utc\t%s\nsince\t%s\nsnapshot\t%s\nbtime\t%s\nweek\t%s\ndrained\t%s\n' "$utc" \
      "$since" "$snap" "$(spl_brs_btime)" "$week" "${SPL_BRX_STOPPED[*]}" > "$dir/pending.tmp" &&
      mv "$dir/pending.tmp" "$dir/pending"; } ||
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
