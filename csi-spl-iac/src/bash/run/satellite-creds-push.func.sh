#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 057 round 1 Q12 A: copy the dev + prd project SA keys and
# @description the GitHub token to the satellite's box user over the IAP ssh,
# @description mode 0600 (dirs 0700), so `ENV=dev|prd ./run -a ...` and git
# @description work there exactly as on this box. Nothing is printed, logged or
# @description put in metadata; the file CONTENTS go over ssh stdin only. The
# @description owner's AI logins are NOT copied (each CLI's own login, R11).
# @description A DRY RUN unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default): list what would be copied. 0: copy.
# @param SATELLITE_CREDS_ENVS (optional) - default "dev prd"
# @param GITHUB_TOKEN_FILE (optional) - default $HOME/.github/token
# @example DRY_RUN=0 ./run -a do_satellite_creds_push
#------------------------------------------------------------------------------
do_satellite_creds_push() {
  do_satellite_ssh_opts || return 1
  local dry_run="${DRY_RUN:-1}" e src dst
  [[ "$dry_run" == 0 || "$dry_run" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  local -a pairs=()
  for e in ${SATELLITE_CREDS_ENVS:-dev prd}; do
    pairs+=("$HOME/.gcp/.csi/key-csi-spl-${e}.json|.gcp/.csi/key-csi-spl-${e}.json")
  done
  pairs+=("${GITHUB_TOKEN_FILE:-$HOME/.github/token}|.github/token")
  local p
  for p in "${pairs[@]}"; do
    src="${p%%|*}" dst="${p#*|}"
    [[ -r "$src" ]] || { do_log "FATAL cannot read $src"; return 1; }
    if [[ "$dry_run" == 1 ]]; then
      do_log "INFO DRY_RUN would copy $src -> ${SATELLITE_HOST}:~/$dst (0600)"
      continue
    fi
    # shellcheck disable=SC2029
    ssh "${SATELLITE_SSH[@]}" "umask 077; mkdir -p \"\$HOME/$(dirname "$dst")\" && cat > \"\$HOME/$dst\" && chmod 600 \"\$HOME/$dst\"" <"$src" \
      || { do_log "FATAL copy of $(basename "$src") to the satellite failed"; return 1; }
    do_log "OK ${SATELLITE_HOST}:~/$dst (0600)"
  done
  [[ "$dry_run" == 1 ]] && do_log "OK DRY_RUN complete: nothing copied. Re-run with DRY_RUN=0."
  return 0
}
