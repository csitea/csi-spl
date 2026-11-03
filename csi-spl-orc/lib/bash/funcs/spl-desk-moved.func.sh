#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_moved_to <workspace> <desk id> [env]: 0 when this desk lives under
# ANOTHER user's state root (do_spl_desk_move, spec 069 section 8.4), so the
# caller must not seat it, mint a key for it or offer a pin for it. Prints
# "<user>\t<how>" (how: entered | sudo, the way the other root was read).
# 1 when the desk is the caller's, or nowhere else, or cannot be checked.
#
# Why (SPL-4699): on sat 2026-11-03 the prd reconcile ran as the box user
# while 11 of 12 desks had moved to the agent user. A writer had left a stub
# <caller root>/desk/<ws>/<id>/spool/<agent> behind during the move, so
# spl_desk_dir found the stub first, do_spl_desk_up_tenants seated it,
# minted a NEW box key and printed a do_spl_desk_pin offer with that key,
# every 5 min: run, it takes the desk from the agent user's live sidecar.
#
# The signal is the desk dir itself under the other user's root: the move
# copies it there and a rollback or MOVE_CMD=back sets that copy aside into
# the other user's desk.moved-<UTC>, so desk/<ws>/<id> exists there only
# while the desk is the other user's. A root the caller cannot enter (0700)
# is read with `sudo -n -u <user> test -d`, the access do_spl_desk_move uses
# (SPL_DESK_AS_CMD overrides it in tests); no sudo rule: unknown, rc 1, as
# before. A desk.moved-* marker is not required: the prune of 8.4 step 6
# removes it after 7 days and the stub stays.
# The caller's own copy wins while its sidecar is live (its hub-run.pid):
# never skip a desk this user is serving.
spl_desk_moved_to() {
  local ws="$1" box="$2" e="${3:-$(spl_desk_env)}" me l u r p mine=""
  [[ -n "$ws" && -n "$box" && -n "$e" ]] || return 1
  me="$(id -un)"
  local -a roots=() as=()
  read -r -a as <<<"${SPL_DESK_AS_CMD:-sudo -n -u}"
  mapfile -t roots < <(spl_desk_roots "$e")
  for l in "${roots[@]}"; do
    u="${l%%$'\t'*}" r="${l#*$'\t'}"
    [[ -n "$r" ]] || continue
    p="$r/desk/$ws/$box"
    if [[ "$u" == "$me" ]]; then mine="$p"; continue; fi
    [[ -n "$mine" ]] && spl_desk_alive "$mine/spool/.hub/hub-run.pid" && return 1
    if spl_desk_root_enterable "$p"; then
      [[ -d "$p" ]] && { printf '%s\tentered\n' "$u"; return 0; }
    elif "${as[@]}" "$u" -- test -d "$p" 2>/dev/null; then
      printf '%s\tsudo\n' "$u"; return 0
    fi
  done
  return 1
}

# spl_desk_moved_note <workspace> <desk id> <user> <how>: the one INFO line a
# reconcile pass logs for a desk it skips because it moved to <user>.
spl_desk_moved_note() {
  do_log "INFO desk $2 of $1 (${ENV:-?}) lives under $3's state root (do_spl_desk_move, spec 069 8.4; read by $4): skipped as $(id -un), no key minted, no pin offered - $3's reconcile and sidecar serve it"
}
