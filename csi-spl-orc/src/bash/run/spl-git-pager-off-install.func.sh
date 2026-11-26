#!/bin/bash
#------------------------------------------------------------------------------
# @description An agent's git never opens a pager (spool-install step Y16,
# @description SPL-2432): core.pager=cat in the global git config of BOTH the
# @description box's agent user (SPOOL_AGENT_USER, else $SPOOL_ROOT/box.env)
# @description and the box user (the user running this; agents run git as it
# @description through sudo -u, whose env_reset drops a launcher GIT_PAGER).
# @description Another user's home is written through sudo -n -u <user>. A
# @description core.pager set by hand to something else is kept and named.
# @description Idempotent. Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param GIT_PAGER_OFF_USERS (optional) - space-separated users, default "<agent user> <box user>"
# @example ./run -a do_spl_git_pager_off_install
# @example DRY_RUN=0 ./run -a do_spl_git_pager_off_install
#------------------------------------------------------------------------------
do_spl_git_pager_off_install() {
  local dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  do_require_bin git || return 1
  _spl_user_step_install "git pager off" \
    "$PROJ_PATH/src/bash/features/spool-install/steps/y16-git-pager-off.sh" \
    spool_install_git_pager_off "${GIT_PAGER_OFF_USERS:-}" "$dry"
}

# _spl_user_step_install <label> <step_file> <fn> <users_override> <dry> [home_suffix] [repo]
# Runs <fn> from <step_file> for each unique user in <users_override> (default:
# SPOOL_AGENT_USER from env or box.env, plus the running user), via sudo -n -u
# for another user. Passes "$home<home_suffix>" "$dry" [repo] to <fn>.
_spl_user_step_install() {
  local label="$1" step="$2" fn="$3" users="$4" dry="$5" hsuf="${6:-}" repo="${7:-}"
  local me agent f u home target seen=" " rc=0
  local -a args=()
  [[ -r "$step" ]] || { do_log "FATAL the step $step is not readable"; return 1; }
  me="$(id -un)"
  if [[ -z "$users" ]]; then
    agent="${SPOOL_AGENT_USER:-}"
    f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
    if [[ -z "$agent" && -r "$f" ]]; then
      agent="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$f" | tail -1 | tr -d "\"'\r")"
    fi
    users="$agent $me"
  fi
  for u in $users; do
    [[ "$seen" == *" $u "* ]] && continue
    seen+="$u "
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home" ]] || { do_log "ERROR no passwd entry for $u"; rc=1; continue; }
    target="${home}${hsuf}"
    args=("$step" "$fn" "$target" "$dry")
    [[ -n "$repo" ]] && args+=("$repo")
    do_log "INFO $label: $u ($target)${repo:+, repo $repo}, DRY_RUN=$dry"
    if [[ "$u" == "$me" ]]; then
      # shellcheck disable=SC2016
      bash -c '. "$1" && "$2" "${@:3}"' _ "${args[@]}" || rc=1
    else
      # shellcheck disable=SC2016
      sudo -n -u "$u" bash -c '. "$1" && "$2" "${@:3}"' _ "${args[@]}" || rc=1
    fi
  done
  [[ "$rc" == 0 ]] && do_log "OK $label: $users (DRY_RUN=$dry)"
  return "$rc"
}
