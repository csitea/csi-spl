#!/bin/bash
#------------------------------------------------------------------------------
# @description Install the Mistral Vibe output cap (spool-install step Y15,
# @description SPL-2217) into the ~/.vibe of BOTH the box's agent user
# @description (SPOOL_AGENT_USER, else $SPOOL_ROOT/box.env) and the box user.
# @description A post_tool hook "spool-output-cap" on bash: a result longer
# @description than VIBE_OUTPUT_CAP_CHARS (4000) reaches the model as its
# @description return code, head and tail plus the path of the full log.
# @description Another user's home is written through sudo -n -u <user>. A
# @description user without ~/.vibe is skipped. Idempotent. Dry run unless
# @description DRY_RUN=0. A running vibe reads hooks.toml at session start.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param VIBE_OUTPUT_CAP_USERS (optional) - space-separated users, default "<agent user> <box user>"
# @example ./run -a do_spl_vibe_output_cap_install
# @example DRY_RUN=0 ./run -a do_spl_vibe_output_cap_install
#------------------------------------------------------------------------------
do_spl_vibe_output_cap_install() {
  local dry="${DRY_RUN:-1}" me agent f users u home step seen=" " rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin python3 || return 1
  step="$PROJ_PATH/src/bash/features/spool-install/steps/y15-vibe-output-cap.sh"
  [[ -r "$step" ]] || { do_log "FATAL the step $step is not readable"; return 1; }
  me="$(id -un)"
  agent="${SPOOL_AGENT_USER:-}"
  f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  if [[ -z "$agent" && -r "$f" ]]; then
    agent="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$f" | tail -1 | tr -d "\"'\r")"
  fi
  users="${VIBE_OUTPUT_CAP_USERS:-$agent $me}"
  for u in $users; do
    [[ "$seen" == *" $u "* ]] && continue
    seen+="$u "
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home" ]] || { do_log "ERROR no passwd entry for $u"; rc=1; continue; }
    do_log "INFO vibe output cap: $u ($home/.vibe), DRY_RUN=$dry"
    if [[ "$u" == "$me" ]]; then
      bash -c '. "$1" && spool_install_vibe_output_cap "$2" "$3"' _ "$step" "$home/.vibe" "$dry" || rc=1
    else
      sudo -n -u "$u" bash -c '. "$1" && spool_install_vibe_output_cap "$2" "$3"' _ "$step" "$home/.vibe" "$dry" || rc=1
    fi
  done
  [[ "$rc" == 0 ]] && do_log "OK vibe output cap: $users (DRY_RUN=$dry)"
  return "$rc"
}
