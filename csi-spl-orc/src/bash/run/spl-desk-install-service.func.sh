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
# @description Dry run unless DRY_RUN=0. --check / DESK_SERVICE_ACTION=check is
# @description read-only and says whether the line is installed.
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
# @param   Default: the SHARED checkout this action would name. A worktree is
# @param   refused: it is deleted when its agent finishes and the job then stops
# @param   silently while still looking installed
# @param DESK_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/desk-reconcile
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DESK_SERVICE_ACTION=check ./run -a do_spl_desk_install_service
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_desk_install_service
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
  # fault it is there to report.
  [[ "$act" == check || -x "$script" ]] ||
    { do_log "FATAL $script is missing or not executable in $src"; return 1; }
  logdir="${DESK_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/desk-reconcile}"

  local mute="${DESK_MUTE:-}" line
  for a in $mute; do
    [[ "$a" =~ ^[A-Z]{2,4}-[0-9]+$ ]] || { do_log "FATAL DESK_MUTE holds '$a', which is not an agent id"; return 1; }
  done
  line="*/$every * * * * ENV=$env_name TENANT_ID=$tenant${mute:+ DESK_MUTE='$mute'} $script >> $logdir/cron.out 2>&1 # $tag"

  local installed=0 current=""
  current="$(spl_desk_cron_line "$tag")"
  [[ -n "$current" ]] && installed=1

  if [[ "$act" == check ]]; then
    python3 - "$installed" "$current" "$line" "$logdir" <<'EOF_PY'
import json, sys
installed, current, want, logdir = sys.argv[1:]
print(json.dumps({"installed": installed == "1", "current": current or None,
                  "expected": want, "matches": current == want,
                  "log_dir": logdir}, sort_keys=True))
EOF_PY
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
  fi


  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    if [[ "$act" == install ]]; then
      do_log "INFO DRY_RUN would: mkdir -p $logdir"
      do_log "INFO DRY_RUN would: put ONE tagged line in the box user's crontab:"
      spl_desk_cron_say "$line"
      (( installed )) && spl_desk_cron_say "replacing the line already there: $current"
    else
      if (( installed )); then
        do_log "INFO DRY_RUN would: remove the tagged crontab line:"
        spl_desk_cron_say "$current"
      else
        do_log "INFO DRY_RUN nothing to remove: no line tagged $tag"
      fi
    fi
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi

  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$tag" "" || return 1
    do_log "OK the desk reconcile is out of the box user's crontab. Nothing re-seats agents now: run do_spl_desk_up_all by hand after a restart"
    return 0
  fi

  mkdir -p "$logdir" 2>/dev/null || { do_log "FATAL cannot create $logdir"; return 1; }
  spl_desk_cron_write "$tag" "$line" || return 1
  current="$(spl_desk_cron_line "$tag")"
  [[ "$current" == "$line" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK the desk reconcile runs every ${every}m as the box user:"
  spl_desk_cron_say "$line"
  do_log "OK verify it later with DESK_SERVICE_ACTION=check ./run -a do_spl_desk_install_service"
}

# The marker that makes this line OURS. Every read and every write matches on
# it, so an operator's own crontab lines are never touched and running the
# install twice replaces rather than appends. Derived from <org>-<app>, like
# every other name in this tree, so a fork of this repo does not fight this one
# over the same crontab line.
spl_desk_cron_tag() { printf '%s:desk-reconcile' "${SPL_ORG_APP:?SPL_ORG_APP unset}"; }

# spl_desk_cron_src: the checkout the cron line points at, into
# SPL_DESK_CRON_SRC. A worktree is refused: it is removed when its agent
# finishes, and a crontab line into a deleted directory keeps LOOKING installed
# while running nothing.
#
# Into a VARIABLE, not onto stdout: do_log writes to stdout, so a caller using
# `src="$(spl_desk_cron_src)"` captures the refusal instead of showing it and
# the operator sees an action that failed with no reason given.
spl_desk_cron_src() {
  local src="${DESK_CRON_SRC:-$APP_PATH}"
  SPL_DESK_CRON_SRC=""
  src="$(cd "$src" 2>/dev/null && pwd)" || { do_log "FATAL DESK_CRON_SRC '${DESK_CRON_SRC:-$APP_PATH}' is not a directory"; return 1; }
  case "$src" in
    *-wt/*)
      do_log "FATAL $src is an agent worktree, and a crontab line into one keeps LOOKING installed after the worktree is removed."
      do_log "FATAL Point DESK_CRON_SRC at the shared checkout, e.g. DESK_CRON_SRC=${src%%-wt/*}"
      return 1 ;;
  esac
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
# nothing. The line is "<schedule> <VAR=v ...> <script> >> <log> 2>&1 # <tag>",
# so the script is the first field that looks like an absolute path.
spl_desk_cron_script() {
  local f
  for f in $1; do
    case "$f" in /*) printf '%s' "$f"; return 0 ;; esac
  done
  return 1
}

# spl_desk_cron_line <tag>: the tagged line in the box user's crontab, or
# nothing.
spl_desk_cron_line() {
  crontab -l 2>/dev/null | grep -F "# $1" | tail -n 1
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
  crontab -l 2>/dev/null | grep -vF "# $tag" >"$tmp"
  [[ -n "$line" ]] && printf '%s\n' "$line" >>"$tmp"
  crontab "$tmp"; rc=$?
  rm -f "$tmp"
  (( rc == 0 )) || { do_log "FATAL crontab refused the new file (exit $rc)"; return 1; }
  return 0
}
