#!/bin/bash
#------------------------------------------------------------------------------
# @description Install or update the private local hub's long-lived tree and
# @description bring it up. The tree ($LOCAL_HUB_TREE, default
# @description <home>/<org>-<app>) is a clone owned by the hub user, never an
# @description agent worktree, so tearing a lane down never touches it.
# @description   first run: clone it (as the hub user) from the caller's own
# @description   origin, as https (the repo is public; no key is shared)
# @description   every run: fetch, `merge --ff-only origin/master`, then
# @description   do_spl_local_hub_up. A tree that cannot fast-forward (a local
# @description   edit) is refused, never reset.
# @param LOCAL_HUB_GIT_URL (optional) - clone from this URL instead
# @param DRY_RUN (optional) - 1: fetch and say what would change, no merge, no up
# @example ./run -a do_spl_local_hub_update
#------------------------------------------------------------------------------
do_spl_local_hub_update() {
  spl_local_hub_cnf || return 1
  if ! spl_local_hub_is_user; then
    _slh_clone || return 1
    spl_local_hub_reexec do_spl_local_hub_update; return
  fi
  local t="$LOCAL_HUB_TREE" before after
  git -C "$t" fetch -q origin master || { do_log "FATAL git fetch in $t failed"; return 1; }
  before="$(git -C "$t" rev-parse HEAD)" after="$(git -C "$t" rev-parse origin/master)"
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    do_log "INFO DRY_RUN: $t at ${before:0:12}, origin/master ${after:0:12}"; return 0
  fi
  if [[ "$before" != "$after" ]]; then
    git -C "$t" merge -q --ff-only origin/master ||
      { do_log "FATAL $t cannot fast-forward to origin/master (local commits or edits?): nothing changed"; return 1; }
    do_log "INFO $t ${before:0:12} -> ${after:0:12}"
  fi
  # the up runs from the updated tree's own code, not from this process
  (cd "$t/${PROJ_PATH##*/}" && exec ./run -a do_spl_local_hub_up)
}

# _slh_clone -- the first run: clone the tree as the hub user.
_slh_clone() {
  local sudo="${LOCAL_HUB_SUDO:-sudo}" url
  $sudo -n -u "$LOCAL_HUB_USER" test -d "$LOCAL_HUB_TREE/.git" && return 0
  id "$LOCAL_HUB_USER" >/dev/null 2>&1 ||
    { do_log "FATAL no user $LOCAL_HUB_USER: run ./run -a do_spl_local_hub_install first"; return 1; }
  url="${LOCAL_HUB_GIT_URL:-$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)}"
  [[ "$url" =~ ^git@([^:]+):(.+)$ ]] && url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  [[ "$url" == https://* ]] || { do_log "FATAL cannot clone from '$url': set LOCAL_HUB_GIT_URL to an https URL"; return 1; }
  do_log "INFO cloning $url into $LOCAL_HUB_TREE as $LOCAL_HUB_USER"
  $sudo -n -u "$LOCAL_HUB_USER" -H git clone -q --branch master "$url" "$LOCAL_HUB_TREE" ||
    { do_log "FATAL git clone failed"; return 1; }
}
