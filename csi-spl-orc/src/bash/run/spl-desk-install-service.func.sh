#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the recurring reconcile that keeps
# @description every live agent on this box seated at the hub, so the desks
# @description survive a restart without a human. CLE-3434 wrote the recovery
# @description command and deliberately did NOT install anything, because a
# @description long-lived job on this box needed the owner's word. The owner
# @description gave it on 2026-09-22: "all of the spuwn agents should be online
# @description for the dev.spool-hub".
# @description The job is ONE crontab line in the box user's crontab, marked
# @description with the tag `# csi-spl:desk-reconcile`, calling
# @description src/bash/scripts/desk-reconcile-cron.sh, which calls
# @description do_spl_desk_up_all. Installing is idempotent: the tagged line is
# @description replaced, never appended, so running this twice leaves one line.
# @description WHY CRON AND NOT A SYSTEMD USER SERVICE - measured on this box
# @description 2026-09-22: the box user has Linger=no and no user bus over a
# @description sudo hop ("$DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not
# @description defined"), so a user unit would first need `loginctl
# @description enable-linger`, which is root, box-wide and permanent; a system
# @description unit needs root under /etc. Cron needs neither, the box user
# @description already has a crontab, and what has to run is a short reconcile
# @description on a schedule - not a supervised daemon, which is the one thing
# @description systemd would actually add.
# @description WHY AN INTERVAL AND NOT @reboot - the measured failure was a TMUX
# @description SERVER restart with no reboot involved, and agents are spawned
# @description all day. A boot hook covers neither. The interval covers both,
# @description and covers a reboot within one tick.
# @description PLUS AN @reboot LINE, because "within one tick" is too slow:
# @description a box booted 16:23:00Z and its prd sidecar came back 16:25:09Z, and
# @description in that gap every cross-box send failed rc=3 ("no live hub-run
# @description sidecar"). So install also writes ONE `@reboot` line per env,
# @description tagged `<tag>@boot`, running the SAME script with --boot: it
# @description waits (bounded) for a default route and the hub's DNS, runs the
# @description reconcile once and logs one BOOT line with the boot time and rc.
# @description No self-update prefix on it: a fetch before the network is up
# @description only fails, and the first tick moves the checkout anyway. The
# @description `@boot` suffix is outside `desk-reconcile(-[a-z]+)?$`, so the
# @description box-restart desk pass (which strips five schedule fields) never
# @description runs the @reboot line.
# @description Dry run unless DRY_RUN=0. --check / DESK_SERVICE_ACTION=check is
# @description read-only and says whether the lines are installed.
# @param DESK_SERVICE_ACTION (optional) - install (default) | remove | check
# @param ENV (optional) - the env baked into the cron line, default dev
# @param TENANT_ID (optional) - the tenant baked into the cron line, default t1
# @param DESK_CRON_EVERY (optional) - minutes between ticks, default 5
# @param DESK_MUTE (optional) - space-separated agent ids the reconcile seats
# @param   with their PROMPT left alone, baked into the cron line. Without it a
# @param   tick would UNDO a deliberate mute: DESK_POKE defaults to 1, so the
# @param   next reconcile removes the .no-poke marker and the seat starts taking
# @param   poke lines again. A mute that a timer quietly reverses is worse than
# @param   no mute, because nobody is watching at the moment it reverses
# @param DESK_CRON_SRC (optional) - the checkout the cron line points at.
# @param   Default: the dedicated SELF-UPDATING checkout <shared checkout>-desk-cron
# @param   (a detached worktree of the shared repo, created on install when
# @param   missing): every tick first moves it to origin/<trunk>, so the cron
# @param   never runs code older than trunk (spec 028 T078/T079). An agent
# @param   worktree (<repo>-wt/...) is refused: it is deleted when its agent
# @param   finishes and the job then stops silently while still looking installed
# @param DESK_CRON_SELF_UPDATE (optional) - 1 prefixes the line with the
# @param   `cd <src> && git fetch && git checkout --detach origin/<trunk>;` step.
# @param   Default 1 for the default source, 0 for an explicit DESK_CRON_SRC
# @param DESK_CRON_TRUNK (optional) - default master
# @param DESK_CRON_OFFSET (optional) - minute offset of the schedule, default
# @param   0 on dev and 1 on any other env, so the dev and prd ticks never start
# @param   in the same minute. 0 gives */N, k gives k-59/N
# @param DESK_CRON_PROBE (optional) - 1 (default on prd) bakes PROBE_EMAIL /
# @param   PROBE_PW_FILE of the m3-e2e member (<state>/m3-e2e/<DESK_CRON_PROBE_TENANT>,
# @param   default e2e) into the line: the prd roster read signs in as a member
# @param ONE LINE PER ENV: the tag is <org>-<app>:desk-reconcile on dev and
# @param   <org>-<app>:desk-reconcile-<env> elsewhere, matched EXACTLY at the end
# @param   of the line, so installing dev never touches the prd line (it did, as a
# @param   prefix match, on 2026-10-01: prd stopped reconciling for 7 minutes)
# @param DESK_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/desk-reconcile
# @param DESK_BOOT_HOST (optional) - the host the @reboot run waits to resolve,
# @param   default env.dns.api_fqdn of the cnf (none: it waits for a route only)
# @param DESK_BOOT_WAIT (optional) - seconds the @reboot run waits, default 180
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DESK_SERVICE_ACTION=check ./run -a do_spl_desk_install_service
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_desk_install_service
# @example ENV=prd TENANT_ID=t1 DESK_MUTE=CLE-00 DESK_CRON_EVERY=3 ./run -a do_spl_desk_install_service
#------------------------------------------------------------------------------
do_spl_desk_install_service() {
  do_require_bin crontab python3 || return 1
  ENV="${ENV:-dev}"
  do_spl_cloud_cnf || return 1
  local act="${DESK_SERVICE_ACTION:-install}"
  case "$act" in install|remove|check) ;; *) do_log "FATAL DESK_SERVICE_ACTION must be install, remove or check, got: '$act'"; return 1 ;; esac
  local every="${DESK_CRON_EVERY:-5}"
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 59 )) || { do_log "FATAL DESK_CRON_EVERY must be 1..59 minutes, got: '$every'"; return 1; }
  local env_name="$ENV" tenant="${TENANT_ID:-t1}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }

  local src script logdir tag
  tag="$(spl_desk_cron_tag)"
  spl_desk_cron_src || return 1
  src="$SPL_DESK_CRON_SRC"
  script="$src/$SPL_ORG_APP-orc/src/bash/scripts/desk-reconcile-cron.sh"
  # A check asks about the line that IS installed, not about the one this call
  # would write, so a missing source script must not stop it - that is the very
  # fault it is there to report. A self-updating checkout that does not exist
  # yet is created by the install itself.
  [[ "$act" != install || -x "$script" || ( "$SPL_DESK_CRON_CREATE" == 1 ) ]] ||
    { do_log "FATAL $script is missing or not executable in $src"; return 1; }
  logdir="${DESK_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/desk-reconcile}"

  local mute="${DESK_MUTE:-}" line
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  for a in $mute; do
    spl_is_participant_id "$a" || { do_log "FATAL DESK_MUTE holds '$a', which is not an agent id"; return 1; }
  done
  line="$(spl_desk_cron_build_line "$every" "$env_name" "$tenant" "$mute" "$src" "$script" "$logdir" "$tag")" || return 1
  # the @reboot twin: same env, mute and probe, no self-update, --boot
  local btag="$tag@boot" bline bcurrent
  bline="$(SPL_DESK_CRON_BOOT=1 spl_desk_cron_build_line "$every" "$env_name" "$tenant" "$mute" "$src" "$script" "$logdir" "$btag")" || return 1
  bcurrent="$(spl_desk_cron_line "$btag")"

  local installed=0 current=""
  current="$(spl_desk_cron_line "$tag")"
  [[ -n "$current" ]] && installed=1

  if [[ "$act" == check ]]; then
    _spl_desk_service_check "$installed" "$current" "$line" "$logdir" "$bcurrent" "$bline"
    return
  fi

  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    _spl_desk_service_dry_plan "$act" "$installed" "$current" "$line" "$tag" "$src" "$logdir" "$btag" "$bline" "$bcurrent"
    return 0
  fi

  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" && spl_desk_cron_write "$btag" "" || return 1
    do_log "OK the desk reconcile (tick and @reboot) is out of the box user's crontab. Nothing re-seats agents now: run do_spl_desk_up_all by hand after a restart"
    return 0
  fi
  _spl_desk_service_install "$src" "$script" "$logdir" "$tag" "$line" "$btag" "$bline" "$every"
}

# _spl_desk_service_install <checkout> <script> <log dir> <tag> <line> <boot
# tag> <boot line> <every>: create the self-updating checkout when missing,
# write both tagged lines and read them back (DRY_RUN=0 install).
_spl_desk_service_install() {
  local src="$1" script="$2" logdir="$3" tag="$4" line="$5" btag="$6" bline="$7" every="$8" got
  if [[ "$SPL_DESK_CRON_CREATE" == 1 ]]; then
    git -C "$SPL_DESK_CRON_REPO" fetch -q origin "${DESK_CRON_TRUNK:-master}" &&
      git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$src" "origin/${DESK_CRON_TRUNK:-master}" ||
      { do_log "FATAL could not create the self-updating checkout $src"; return 1; }
    [[ -x "$script" ]] || { do_log "FATAL $script is missing in the new checkout $src"; return 1; }
  fi
  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" && spl_desk_cron_write "$btag" "$bline" || return 1
  got="$(spl_desk_cron_line "$tag")"
  [[ "$got" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${got:-<nothing>}"; return 1; }
  got="$(spl_desk_cron_line "$btag")"
  [[ "$got" == "$bline" ]] || { do_log "FATAL the crontab does not read back the @reboot line. Got: ${got:-<nothing>}"; return 1; }
  do_log "OK the desk reconcile runs every ${every}m, and once at boot, as the box user:"
  spl_desk_cron_say "$line"
  spl_desk_cron_say "$bline"
  do_log "OK verify it later with DESK_SERVICE_ACTION=check ./run -a do_spl_desk_install_service"
}

# _spl_desk_service_check <installed 0|1> <current line> <wanted line> <log dir>
# <current boot line> <wanted boot line>: the JSON state of the reconcile's
# crontab lines, then the verdict; 0 when the installed tick line can still run.
# A missing @reboot line is a WARN, not a FAIL: the tick still re-seats every
# desk, only ~2 minutes later after a boot.
_spl_desk_service_check() {
  local installed="$1" current="$2" line="$3" logdir="$4" bcurrent="$5" bline="$6"
  python3 - "$installed" "$current" "$line" "$logdir" "$bcurrent" "$bline" <<'EOF_PY'
import json, sys
installed, current, want, logdir, bcur, bwant = sys.argv[1:]
print(json.dumps({"installed": installed == "1", "current": current or None,
                "expected": want, "matches": current == want,
                "boot_installed": bool(bcur), "boot_current": bcur or None,
                "boot_expected": bwant, "log_dir": logdir}, sort_keys=True))
EOF_PY
  [[ -n "$bcurrent" ]] ||
    do_log "WARN no @reboot desk reconcile line: after a boot the sidecars wait for the next tick. Install: DRY_RUN=0 ./run -a do_spl_desk_install_service"
  # The verdict is "can this line still run", not "does it match the flags I
  # happen to have set". An operator who installed it with a different
  # interval, env or tenant has a WORKING reconcile, and failing that check
  # would train people to ignore it. What is NOT working is a line whose
  # script is gone - the measured way this rots, because a crontab pointing
  # into a removed worktree keeps looking installed forever.
  if (( installed )); then
    local ran; ran="$(spl_desk_cron_script "$current")"
    if [[ -n "$ran" && ! -x "$ran" ]]; then
      spl_desk_cron_say "$current"
      do_log "FAIL the desk reconcile is installed but the script it names is gone or not executable: $ran"
      do_log "FAIL That line runs NOTHING while still looking installed. Re-install: DRY_RUN=0 ./run -a do_spl_desk_install_service"
      return 1
    fi
    [[ "$current" == "$line" ]] ||
      do_log "INFO it was installed with different settings than this call would write - working, but not what these flags say. Installed: $current"
    do_log "OK the desk reconcile is installed in the box user's crontab and the script it names is executable"
    return 0
  fi
  do_log "FAIL the desk reconcile is NOT installed: every agent on this box stays offline after the next tmux or box restart until someone notices"
  return 1
}

# _spl_desk_service_dry_plan <act> <installed 0|1> <current line> <wanted line>
# <tag> <checkout> <log dir> <boot tag> <boot line> <current boot line>: what
# install / remove would do (DRY_RUN=1).
_spl_desk_service_dry_plan() {
  local act="$1" installed="$2" current="$3" line="$4" tag="$5" src="$6" logdir="$7"
  local btag="$8" bline="$9" bcurrent="${10}"
  spl_desk_cron_diff "$tag" "$([[ "$act" == install ]] && printf '%s' "$line")"
  spl_desk_cron_diff "$btag" "$([[ "$act" == install ]] && printf '%s' "$bline")"
  if [[ "$act" == install ]]; then
    [[ "$SPL_DESK_CRON_CREATE" == 1 ]] &&
      do_log "INFO DRY_RUN would: git worktree add --detach $src origin/${DESK_CRON_TRUNK:-master} (the self-updating checkout)"
    do_log "INFO DRY_RUN would: mkdir -p $logdir"
    do_log "INFO DRY_RUN would: put the tick line and its @reboot twin in the box user's crontab:"
    spl_desk_cron_say "$line"
    spl_desk_cron_say "$bline"
    (( installed )) && spl_desk_cron_say "replacing the line already there: $current"
    [[ -n "$bcurrent" ]] && spl_desk_cron_say "replacing the @reboot line already there: $bcurrent"
  else
    if (( installed )); then
      do_log "INFO DRY_RUN would: remove the tagged crontab line:"
      spl_desk_cron_say "$current"
    fi
    if [[ -n "$bcurrent" ]]; then
      do_log "INFO DRY_RUN would: remove the @reboot line:"
      spl_desk_cron_say "$bcurrent"
    elif (( ! installed )); then
      do_log "INFO DRY_RUN nothing to remove: no line tagged $tag"
    fi
  fi
  do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
}

# The marker that makes this line OURS. Every read and every write matches on
# it, so an operator's own crontab lines are never touched and running the
# install twice replaces rather than appends. Derived from <org>-<app>, like
# every other name in this tree, so a fork of this repo does not fight this one
# over the same crontab line.
# One tag per env: dev keeps the original tag (the line installed since
# 2026-09-22), every other env gets -<env> (the prd line of spec 028 T079).
spl_desk_cron_tag() {
  local e="${ENV:-dev}"
  printf '%s:desk-reconcile%s' "${SPL_ORG_APP:?SPL_ORG_APP unset}" "$([[ "$e" == dev ]] || printf -- '-%s' "$e")"
}

# spl_desk_cron_build_line <every> <env> <tenant> <mute> <src> <script> <logdir> <tag>
# SPL_DESK_CRON_BOOT=1 builds the @reboot twin instead: schedule @reboot, the
# boot gate (spl_cron_boot_gate) in place of the self-update prefix, DESK_BOOT_HOST (the hub's api_fqdn from the cnf) and
# DESK_BOOT_WAIT when set, and the script run with --boot.
spl_desk_cron_build_line() {
  local every="$1" env_name="$2" tenant="$3" mute="$4" src="$5" script="$6" logdir="$7" tag="$8"
  local off sched pre="" probe="" mutev="" out="cron.out" trunk="${DESK_CRON_TRUNK:-master}"
  local boot="${SPL_DESK_CRON_BOOT:-0}" bootv="" arg=""
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  off="${DESK_CRON_OFFSET:-$([[ "$env_name" == dev ]] && echo 0 || echo 1)}"
  [[ "$off" =~ ^[0-9]+$ ]] && (( off < every || off == 0 )) ||
    { do_log "FATAL DESK_CRON_OFFSET must be 0..$((every - 1)), got: '$off'"; return 1; }
  if (( off == 0 )); then sched="*/$every * * * *"; else sched="$off-59/$every * * * *"; fi
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] &&
    pre="cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; "
  [[ "$env_name" == dev ]] || out="cron-$env_name.out"
  if [[ "$boot" == 1 ]]; then
    sched="@reboot" arg=" --boot"
    pre="$(spl_cron_boot_gate "$logdir/$out" "$script" "$tag")" || return 1
    spl_desk_cron_boot_env || return 1
    bootv="$SPL_DESK_CRON_BOOT_ENV"
  fi
  if [[ -n "$mute" ]]; then
    if [[ "$mute" == *" "* ]]; then mutev=" DESK_MUTE='$mute'"; else mutev=" DESK_MUTE=$mute"; fi
  fi
  if [[ "${DESK_CRON_PROBE:-$([[ "$env_name" == prd ]] && echo 1 || echo 0)}" == 1 ]]; then
    local pt="${DESK_CRON_PROBE_TENANT:-e2e}"
    [[ "$pt" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL DESK_CRON_PROBE_TENANT is not a tenant slug: '$pt'"; return 1; }
    local d="\$HOME/.local/share/$SPL_ORG_APP/cloud/$env_name/m3-e2e/$pt"
    probe=" PROBE_EMAIL=\$(cat $d/human-email) PROBE_PW_FILE=$d/pw-human"
  fi
  printf '%s %sENV=%s TENANT_ID=%s%s%s%s %s%s >> %s/%s 2>&1 # %s\n' \
    "$sched" "$pre" "$env_name" "$tenant" "$mutev" "$probe" "$bootv" "$script" "$arg" "$logdir" "$out" "$tag"
}

# spl_desk_cron_boot_env: the " DESK_BOOT_HOST=<h>[ DESK_BOOT_WAIT=<s>]" the
# @reboot line carries, into SPL_DESK_CRON_BOOT_ENV. The host is read from the
# cnf here, at install time, so the boot run needs no yq and no cnf merge before
# the network is up; DESK_BOOT_HOST overrides it.
spl_desk_cron_boot_env() {
  local h="${DESK_BOOT_HOST:-}" w="${DESK_BOOT_WAIT:-}"
  SPL_DESK_CRON_BOOT_ENV=""
  if [[ -z "$h" && -n "${SPL_CNF:-}" && -r "$SPL_CNF" ]] && command -v yq >/dev/null 2>&1; then
    h="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF" 2>/dev/null)"
  fi
  [[ -z "$h" || "$h" =~ ^[A-Za-z0-9.-]+$ ]] || { do_log "FATAL DESK_BOOT_HOST is not a host name: '$h'"; return 1; }
  [[ -z "$w" || "$w" =~ ^[0-9]+$ ]] || { do_log "FATAL DESK_BOOT_WAIT must be seconds, got: '$w'"; return 1; }
  [[ -n "$h" ]] && SPL_DESK_CRON_BOOT_ENV=" DESK_BOOT_HOST=$h"
  [[ -n "$w" ]] && SPL_DESK_CRON_BOOT_ENV+=" DESK_BOOT_WAIT=$w"
  return 0
}

# spl_cron_boot_gate <log file> <needed path> <tag>: the shell every @reboot
# line runs BEFORE its command. Drill 8 on sat, 2026-10-09: cron ran the five
# @reboot jobs at 18:38:48Z while /opt, /var/csi and /var/spool-hub (nofail
# binds of /mnt/data, not ordered before cron) mounted 1..6 s later. Every
# `>> /var/csi/...` redirect failed ("Directory nonexistent"), so no job ran,
# and cron mailed the error to no MTA: not one line anywhere. The gate waits
# (bounded, BOOT_CRON_WAIT seconds, default 300) for the needed path and the
# log's dir, writes a ` BOOT start ` line to the log (to syslog when the log
# never came), then waits (same bound) for network-online.target, so a git or
# DNS step after it finds the network. Plain sh, no `%` (cron's newline). The
# needed path comes first: spec 068 8.1 reads a line's first path as its script.
spl_cron_boot_gate() {
  local log="$1" need="$2" tag="$3" w="${BOOT_CRON_WAIT:-300}"
  [[ "$w" =~ ^[0-9]+$ ]] || { do_log "FATAL BOOT_CRON_WAIT must be seconds, got: '$w'"; return 1; }
  [[ "$log" =~ ^/[A-Za-z0-9._/@-]+$ && "$need" =~ ^/[A-Za-z0-9._/@-]+$ ]] ||
    { do_log "FATAL the boot gate takes plain absolute paths, got: '$log' '$need'"; return 1; }
  printf 'i=0; until [ -e %s ] && [ -d %s ] || [ $i -ge %s ]; do sleep 1; i=$((i+1)); done; ' "$need" "${log%/*}" "$w"
  printf 'echo "$(date -u -Iseconds) BOOT start %s waited ${i}s" 2>/dev/null >> %s || logger -t %s "BOOT start %s: no %s after ${i}s"; ' \
    "$tag" "$log" "${tag%%:*}" "$tag" "$log"
  printf 'n=0; until [ ! -d /run/systemd/system ] || systemctl is-active -q network-online.target || [ $n -ge %s ]; do sleep 1; n=$((n+1)); done; ' "$w"
}

# spl_desk_cron_diff <tag> <new line|"">: the crontab before and after, as a
# unified diff, without writing anything.
spl_desk_cron_diff() {
  local tmp; tmp="$(mktemp -d)" || return 1
  crontab -l 2>/dev/null >"$tmp/before"
  spl_desk_cron_render "$1" "$2" <"$tmp/before" >"$tmp/after"
  echo "    crontab diff (before -> after):"
  diff -u --label before --label after "$tmp/before" "$tmp/after" | sed 's/^/    /'
  cmp -s "$tmp/before" "$tmp/after" && echo "    (no change)"
  rm -rf "$tmp"
}

# spl_desk_cron_render <tag> <line|"">: stdin (a crontab) with the line tagged
# EXACTLY <tag> (the tag ends the line) replaced IN PLACE by <line>, further
# copies dropped, <line> appended when there was none; an empty <line> removes.
# Exact, not a prefix: a prefix match took the -prd line with a dev install on
# 2026-10-01. In place: a re-install that changes nothing changes no byte.
spl_desk_cron_render() {
  # the line through ENVIRON, not -v: -v would interpret backslashes in it
  SPL_CRON_LINE="$2" awk -v t="# $1" '
    BEGIN { l = ENVIRON["SPL_CRON_LINE"] }
    length($0) >= length(t) && substr($0, length($0) - length(t) + 1) == t { if (!done && l != "") print l; done = 1; next }
    { print }
    END { if (!done && l != "") print l }'
}

# spl_desk_cron_src: the checkout the cron line points at, into
# SPL_DESK_CRON_SRC. A worktree is refused: it is removed when its agent
# finishes, and a crontab line into a deleted directory keeps LOOKING installed
# while running nothing.
#
# Into a VARIABLE, not onto stdout: do_log writes to stdout, so a caller using
# `src="$(spl_desk_cron_src)"` captures the refusal instead of showing it and
# the operator sees an action that failed with no reason given.
spl_desk_cron_src() {
  local src
  SPL_DESK_CRON_SRC="" SPL_DESK_CRON_CREATE=0 SPL_DESK_CRON_REPO=""
  if [[ -n "${DESK_CRON_SRC:-}" ]]; then
    SPL_DESK_CRON_SELF_UPDATE="${DESK_CRON_SELF_UPDATE:-0}"
    src="$(cd "$DESK_CRON_SRC" 2>/dev/null && pwd)" || { do_log "FATAL DESK_CRON_SRC '$DESK_CRON_SRC' is not a directory"; return 1; }
  else
    # <shared checkout>-desk-cron, next to the SHARED checkout even when this
    # runs from an agent worktree (the common git dir names the shared one)
    SPL_DESK_CRON_SELF_UPDATE="${DESK_CRON_SELF_UPDATE:-1}"
    local common
    common="$(git -C "$APP_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
      { do_log "FATAL $APP_PATH is not a git checkout - set DESK_CRON_SRC"; return 1; }
    SPL_DESK_CRON_REPO="$(dirname "$common")"
    src="$SPL_DESK_CRON_REPO-desk-cron"
    [[ -d "$src" ]] || SPL_DESK_CRON_CREATE=1
  fi
  case "$src" in
    *-wt/*)
      do_log "FATAL $src is an agent worktree, and a crontab line into one keeps LOOKING installed after the worktree is removed."
      do_log "FATAL Point DESK_CRON_SRC at the shared checkout, e.g. DESK_CRON_SRC=${src%%-wt/*}"
      return 1 ;;
  esac
  [[ "$SPL_DESK_CRON_SELF_UPDATE" == 0 || "$SPL_DESK_CRON_SELF_UPDATE" == 1 ]] ||
    { do_log "FATAL DESK_CRON_SELF_UPDATE must be 0 or 1"; return 1; }
  SPL_DESK_CRON_SRC="$src"
}

# spl_desk_cron_say <line>: print a crontab line for a human to read.
#
# NOT through do_log. A crontab schedule starts with "*/5 * * * *", do_log
# expands its argument, and the asterisks then come out as the contents of the
# current directory - measured 2026-09-22, an operator was shown
# "*/5 dat lib Makefile README.md run src ...". The FILE was always written
# correctly (printf '%s' with the value quoted); it was the line the operator
# reads that was a lie, which is the worse of the two to leave in place.
spl_desk_cron_say() {
  printf '    %s\n' "$1"
}

# spl_desk_cron_script <crontab line>: the script path that line runs, or
# nothing. The line is "<schedule> [cd <src> && git ...;] <VAR=v ...> <script>
# >> <log> 2>&1 # <tag>", so the script is the first absolute path ending .sh
# (not the `cd <dir>` of the self-update step, which is a directory).
spl_desk_cron_script() {
  local f
  set -f
  for f in $1; do
    case "$f" in /*.sh) printf '%s' "$f"; set +f; return 0 ;; esac
  done
  set +f
  return 1
}

# spl_desk_cron_line <tag>: the tagged line in the box user's crontab, or
# nothing.
spl_desk_cron_line() {
  crontab -l 2>/dev/null | awk -v t="# $1" 'length($0) >= length(t) && substr($0, length($0) - length(t) + 1) == t' | tail -n 1
}

# spl_desk_cron_write <tag> <line|"">: put exactly LINE in the crontab under
# TAG, dropping any line that carries it. An empty LINE removes it.
#
# Read-modify-write of the WHOLE crontab, filtered by the tag, never `crontab -l
# | { cat; echo line; } | crontab -`: appending is how a crontab collects four
# copies of the same job over four installs.
spl_desk_cron_write() {
  local tag="$1" line="$2" tmp rc
  tmp="$(mktemp)" || return 1
  crontab -l 2>/dev/null | spl_desk_cron_render "$tag" "$line" >"$tmp"
  crontab "$tmp"; rc=$?
  rm -f "$tmp"
  (( rc == 0 )) || { do_log "FATAL crontab refused the new file (exit $rc)"; return 1; }
  return 0
}
