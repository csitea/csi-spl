#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-2677: keep the two users of the overlay's MASTER box equal.
# @description do_spl_private_overlay_pull keeps every other box equal to the
# @description master box (SPL_PRIVATE_MASTER_BOX, default sat), for both
# @description users; nothing kept the master box's own two users equal. A new
# @description hidden tenant (spl_private_add, run by do_spl_tenant_host_
# @description provision as the box owner) wrote only the owner's copy, and
# @description every lane (the agent user) then FATALed on the new placeholder
# @description (do_check_deploy_lag ENV=prd, 2026-10-19 ws-hidden-14).
# @description   1. only on the master box: spl_desk_box_default must be
# @description      SPL_PRIVATE_MASTER_BOX; any other box pulls instead
# @description   2. the users are OWNER_USER and AGENT_USER of this box's
# @description      /etc/csi-spl-satellite.env (BOX_TAG must be this box)
# @description   3. the source is SYNC_FROM_USER (default the owner user); it
# @description      must exist, be non-empty and not a symlink. Defaulted, a
# @description      target copy that differs AND is newer is refused: name the
# @description      source with SYNC_FROM_USER to choose
# @description   4. the target is written by the pull action's step
# @description      (spl_ppo_put_verify: owner, mode 600 or 640 with a named
# @description      ACL entry, spl_gsp_fix / spl_gsp_check, sha256 checked),
# @description      the content piped root -> root, never in argv, a log or
# @description      stdout. Prints path, mode, owner, sha256_equal=yes|no.
# @description Dry run unless DRY_RUN=0 (prints both verify lines, writes nothing).
# @param SYNC_FROM_USER (optional) - the user whose copy is the master, default OWNER_USER
# @param SPL_PRIVATE_MASTER_BOX (optional) - default sat
# @param SATELLITE_ENV_FILE (optional) - default /etc/csi-spl-satellite.env
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DRY_RUN=0 ./run -a do_spl_private_overlay_sync
#------------------------------------------------------------------------------
do_spl_private_overlay_sync() {
  do_require_bin sha256sum getent || return 1
  local master="${SPL_PRIVATE_MASTER_BOX:-sat}" here dry=1 envf users_line
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  here="$(spl_desk_box_default)"
  [[ "$here" == "$master" ]] ||
    { do_log "FATAL this box ($here) does not hold the master private overlay (box $master): nothing synced. Here: cd csi-spl-orc && DRY_RUN=0 FROM_BOX=$master ./run -a do_spl_private_overlay_pull"; return 1; }
  envf="$(cat "${SATELLITE_ENV_FILE:-/etc/csi-spl-satellite.env}" 2>/dev/null)" ||
    { do_log "FATAL cannot read ${SATELLITE_ENV_FILE:-/etc/csi-spl-satellite.env}: nothing synced"; return 1; }
  users_line="$(spl_ppo_env_users "$envf" "$master" "this box's satellite env names")" || return 1
  local -a users; read -r -a users <<<"$users_line"
  (( ${#users[@]} == 2 )) || { do_log "OK one box user (${users[0]}): nothing to sync"; return 0; }

  local from="${SYNC_FROM_USER:-${users[0]}}" to
  case "$from" in
    "${users[0]}") to="${users[1]}" ;;
    "${users[1]}") to="${users[0]}" ;;
    *) do_log "FATAL SYNC_FROM_USER must be ${users[0]} or ${users[1]}, got: '$from'"; return 1 ;;
  esac
  local hf ht
  hf="$(getent passwd "$from" | cut -d: -f6)"; ht="$(getent passwd "$to" | cut -d: -f6)"
  [[ -n "$hf" && -n "$ht" ]] || { do_log "FATAL user $from or $to does not exist here: nothing synced"; return 1; }
  local src="$hf/.gcp/.csi/csi-spl-private.yaml" dst="$ht/.gcp/.csi/csi-spl-private.yaml" sha rf rt
  sha="$(sudo -n bash -c '[ -s "$1" ] && [ ! -L "$1" ] && sha256sum <"$1" | cut -d" " -f1' spl-private-overlay-sync "$src" </dev/null 2>/dev/null)"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] ||
    { do_log "FATAL no overlay for $from here ($src missing, empty or a symlink): nothing synced"; return 1; }
  rf="$(sudo -n readlink -f "$hf/.gcp" 2>/dev/null)"; rt="$(sudo -n readlink -f "$ht/.gcp" 2>/dev/null)"
  if [[ -n "$rf" && "$rf" == "$rt" ]]; then
    do_log "OK $to's ~/.gcp is $from's ($rf): one file, nothing to sync"; return 0
  fi
  spl_pos_newer_guard "$from" "$to" "$src" "$dst" "$sha" || return 1

  if (( dry )); then
    spl_ppo_verify_one "$from" "$hf" "$sha"
    spl_ppo_verify_one "$to" "$ht" "$sha"
    do_log "INFO DRY_RUN would: copy $src to $dst, owner $to, mode 600 + secret ACL step"
    do_log "OK DRY_RUN nothing was synced. Re-run with DRY_RUN=0 to sync."
    return 0
  fi
  spl_ppo_verify_one "$from" "$hf" "$sha" || return 1
  sudo -n cat "$src" </dev/null 2>/dev/null | spl_ppo_put_verify "$to" "$ht" "$sha" || return 1
  do_log "OK the private overlay of $to equals $from's on box $master, verified"
}

# spl_pos_newer_guard <from> <to> <src> <dst> <sha>: with SYNC_FROM_USER
# unset, refuse a target that differs from the source and is newer than it
# (it may hold a line the source lacks: a person picks the master copy).
spl_pos_newer_guard() {
  [[ -n "${SYNC_FROM_USER:-}" ]] && return 0
  local from="$1" to="$2" src="$3" dst="$4" sha="$5" t
  t="$(sudo -n bash -c '[ -f "$2" ] || exit 0; [ "$(sha256sum <"$2" | cut -d" " -f1)" = "$3" ] && exit 0
[ "$2" -nt "$1" ] && echo newer' spl-private-overlay-sync "$src" "$dst" "$sha" </dev/null 2>/dev/null)"
  [[ "$t" != newer ]] && return 0
  do_log "FATAL $to's overlay differs from $from's and is newer: nothing synced. Choose the master copy: SYNC_FROM_USER=$to (or $from) DRY_RUN=0 ./run -a do_spl_private_overlay_sync"
  return 1
}
