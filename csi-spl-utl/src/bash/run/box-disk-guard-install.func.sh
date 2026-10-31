#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or check, or remove) the box disk guard in the box
# @description user's crontab: three lines, each tagged `# <org>-<app>:<name>`
# @description at its end, so no other job is touched:
# @description   disk-headroom  - csi-spl-orc check-disk-headroom.sh every 15 min
# @description                    (7-59/15), from the self-updating desk checkout,
# @description                    moved to origin/<trunk> under the desk-cron
# @description                    checkout lock (spl_desk_cron_update_pre, SPL-2672),
# @description                    the job behind its own no-stack lock
# @description                    (cron-no-stack.sh, <var>/disk-headroom/cron.lock,
# @description                    SPL-4495), the same line as
# @description                    do_check_disk_headroom_install_cron writes
# @description   box-disk-sweep - csi-spl-orc box-disk-sweep.sh every 15 min
# @description                    (11-59/15), gated and locked (SPL-2053)
# @description   disk-growth    - this module's do_box_disk_inventory once a day
# @description                    (03:23), appending the growth record
# @description The box-disk-sweep line is byte for byte the one SPL-2053
# @description hand-installed; the SPL-2053 disk-headroom line (no lock) reads
# @description "differs" until an install replaces it.
# @description Idempotent: a tagged line is replaced in place, a missing one is
# @description appended. --check prints installed / missing / differs per line
# @description and exits 1 unless all three are installed. Dry run unless DRY_RUN=0.
# @arg --check DISK_GUARD_CHECK
# @param DISK_GUARD_ACTION (optional) - install (default) | check | remove
# @param DISK_GUARD_SRC (optional) - the main checkout, default /opt/<org>/<org>-<app>
# @param DISK_GUARD_DESK_SRC (optional) - the self-updating checkout, default <src>-desk-cron
# @param DISK_GUARD_VAR (optional) - the state dir, default /var/<org>/<org>-<app>
# @param DESK_CRON_TRUNK (optional) - the trunk the desk checkout follows, default master
# @param DISK_GUARD_CRONTAB (optional) - the crontab binary (tests), default crontab
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_box_disk_guard_install --check
# @example ./run -a do_box_disk_guard_install
# @example DRY_RUN=0 ./run -a do_box_disk_guard_install
# @example DISK_GUARD_ACTION=remove DRY_RUN=0 ./run -a do_box_disk_guard_install
#------------------------------------------------------------------------------
declare -F spl_desk_cron_update_pre >/dev/null || {
  _dg_utl="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  source "${_dg_utl%-utl}-orc/lib/bash/funcs/spl-desk-cron-lock.func.sh"
  unset _dg_utl
}

# disk_guard_lines: the three wanted lines, one per row, in tag order
disk_guard_lines() {
  local app="$1" src="$2" desk="$3" var="$4" trunk="$5"
  printf '%s\n' \
    "7-59/15 * * * * $(spl_desk_cron_update_pre "$desk" "$trunk")DRY_RUN=0 $(spl_cron_no_stack_pre "$desk/$app-orc" "$var/disk-headroom/cron.lock")$desk/$app-orc/src/bash/scripts/check-disk-headroom.sh >> $var/disk-headroom/cron.out 2>&1 # $app:disk-headroom" \
    "11-59/15 * * * * DRY_RUN=0 BOX_SWEEP_GATE=1 BOX_SWEEP_LOCK=$var/box-disk-sweep/box-disk-sweep.lock bash $src/$app-orc/src/bash/scripts/box-disk-sweep.sh >> $var/box-disk-sweep/box-disk-sweep.log 2>&1 # $app:box-disk-sweep" \
    "23 3 * * * cd $desk/$app-utl && DRY_RUN=0 ./run -a do_box_disk_inventory >> $var/box-disk-sweep/growth.cron.out 2>&1 # $app:disk-growth"
}

do_box_disk_guard_install() {
  local cron="${DISK_GUARD_CRONTAB:-crontab}" act="${DISK_GUARD_ACTION:-install}"
  [[ "${DISK_GUARD_CHECK:-}" == true ]] && act=check
  case "$act" in install|check|remove) ;; *) do_log "FATAL DISK_GUARD_ACTION must be install, check or remove, got: '$act'"; return 1 ;; esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  command -v "$cron" >/dev/null 2>&1 || { do_log "FATAL $cron is not on PATH"; return 1; }

  local app org src desk var
  app="$(basename "$PROJ_PATH")"; app="${app%-utl}"; org="${app%%-*}"
  src="${DISK_GUARD_SRC:-/opt/$org/$app}"
  desk="${DISK_GUARD_DESK_SRC:-$src-desk-cron}"
  var="${DISK_GUARD_VAR:-/var/$org/$app}"
  local trunk="${DESK_CRON_TRUNK:-master}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }

  local cur want=() tags=() l t
  cur="$("$cron" -l 2>/dev/null || true)"
  mapfile -t want < <(disk_guard_lines "$app" "$src" "$desk" "$var" "$trunk")
  for l in "${want[@]}"; do tags+=("${l##* # }"); done

  # per line: installed / missing / differs
  local bad=0 have i
  for i in "${!want[@]}"; do
    t="${tags[$i]}"
    have="$(grep -F -- " # $t" <<<"$cur" | grep -E -- " # ${t//./\\.}\$" | head -n 1 || true)"
    if [[ -z "$have" ]]; then
      echo "missing   $t"; bad=$((bad + 1))
    elif [[ "$have" == "${want[$i]}" ]]; then
      echo "installed $t"
    else
      echo "differs   $t"; echo "  have: $have"; echo "  want: ${want[$i]}"; bad=$((bad + 1))
    fi
  done
  if [[ "$act" == check ]]; then
    (( bad == 0 )) && { do_log "OK the disk guard is installed: ${#want[@]} of ${#want[@]} lines"; return 0; }
    do_log "FAIL the disk guard is not fully installed: $bad of ${#want[@]} lines missing or different"
    return 1
  fi

  # the new crontab: tagged lines replaced in place, missing ones appended
  local next="" seen=() line
  while IFS= read -r line || [[ -n "$line" ]]; do
    for i in "${!tags[@]}"; do
      if [[ "$line" == *" # ${tags[$i]}" ]]; then
        [[ "$act" == install && -z "${seen[$i]:-}" ]] && next+="${want[$i]}"$'\n'
        seen[$i]=1; continue 2
      fi
    done
    next+="$line"$'\n'
  done <<<"$cur"
  [[ -z "$cur" ]] && next=""
  if [[ "$act" == install ]]; then
    for i in "${!want[@]}"; do [[ -n "${seen[$i]:-}" ]] || next+="${want[$i]}"$'\n'; done
  fi

  if [[ "$next" == "$cur"$'\n' || ( -z "$cur" && -z "$next" ) ]]; then
    do_log "OK nothing to change: the crontab already reads as wanted ($act)"
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    diff <(printf '%s\n' "$cur") <(printf '%s' "$next") || true
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  if [[ "$act" == install ]]; then
    [[ -x "$src/$app-orc/src/bash/scripts/box-disk-sweep.sh" ]] || { do_log "FATAL $src/$app-orc/src/bash/scripts/box-disk-sweep.sh is missing or not executable"; return 1; }
    [[ -x "$desk/$app-utl/run" ]] || { do_log "FATAL $desk/$app-utl/run is missing: is the desk checkout ($desk) there?"; return 1; }
    mkdir -p "$var/disk-headroom" "$var/box-disk-sweep" 2>/dev/null || { do_log "FATAL cannot create the log dirs under $var"; return 1; }
  fi
  printf '%s' "$next" | "$cron" - || { do_log "FATAL $cron refused the new crontab"; return 1; }
  DISK_GUARD_ACTION=check DISK_GUARD_CHECK="" DRY_RUN=1 do_box_disk_guard_install >/dev/null
  local rc=$?
  if [[ "$act" == install ]]; then
    (( rc == 0 )) || { do_log "FATAL the crontab does not read back the three lines"; return 1; }
    do_log "OK the disk guard is installed (${#want[@]} lines)"
  else
    do_log "OK the disk guard lines are out of the crontab"
  fi
}
