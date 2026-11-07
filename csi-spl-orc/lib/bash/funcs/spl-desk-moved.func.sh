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
# The signal is asymmetric (R7 W1): the desk is moved only when the OTHER
# user's copy is a real, pinned desk (desk/<ws>/<id>/pinned, written by
# do_spl_desk_pin / do_spl_desk_up) AND the caller's copy is not pinned (a
# stub, or absent). A stub may hold keys/ (the box user's reconcile minted
# keys into the sat stubs), so keys/ proves nothing; pinned does. Symmetric,
# the agent user's reconcile skipped its OWN pinned desk whenever its
# sidecar was down (a reboot) and a box-user stub existed: nobody served it.
# A move copies the desk with its pinned file and sets the source aside into
# desk.moved-<UTC>; a rollback or MOVE_CMD=back sets the other copy aside,
# so a pinned desk/<ws>/<id> exists there only while the desk is that user's.
# A root the caller cannot enter (0700) is read with
# `sudo -n -u <user> test -s`, the access do_spl_desk_move uses
# (SPL_DESK_AS_CMD overrides it in tests); no sudo rule: one WARN line on
# stderr, rc 1, behaviour as before. A desk.moved-* marker is not used: the
# prune of 8.4 step 6 removes it after 7 days and the stub stays.
# The caller's own copy also wins while its sidecar is live (hub-run.pid).
spl_desk_moved_to() {
  local ws="$1" box="$2" e="${3:-$(spl_desk_env)}" me l u r p
  [[ -n "$ws" && -n "$box" && -n "$e" ]] || return 1
  me="$(id -un)"
  local -a roots=() as=() others=()
  read -r -a as <<<"${SPL_DESK_AS_CMD:-sudo -n -u}"
  mapfile -t roots < <(spl_desk_roots "$e")
  for l in "${roots[@]}"; do
    u="${l%%$'\t'*}" r="${l#*$'\t'}"
    [[ -n "$r" ]] || continue
    p="$r/desk/$ws/$box"
    if [[ "$u" != "$me" ]]; then others+=("$u"$'\t'"$p"); continue; fi
    [[ -s "$p/pinned" ]] && return 1
    spl_desk_alive "$p/spool/.hub/hub-run.pid" && return 1
  done
  for l in "${others[@]}"; do
    u="${l%%$'\t'*}" p="${l#*$'\t'}"
    if spl_desk_root_enterable "$p"; then
      [[ -s "$p/pinned" ]] && { printf '%s\tentered\n' "$u"; return 0; }
    elif "${as[@]}" "$u" -- test -s "$p/pinned" 2>/dev/null; then
      printf '%s\tsudo\n' "$u"; return 0
    elif ! "${as[@]}" "$u" -- true 2>/dev/null; then
      do_log "WARN desk $box of $ws ($e): cannot check $u's root as $me (no sudo -n rule to $u): not known as moved, reconciled as before" >&2
    fi
  done
  return 1
}

# spl_desk_moved_note <workspace> <desk id> <user> <how>: the one INFO line a
# reconcile pass logs for a desk it skips because it moved to <user>.
spl_desk_moved_note() {
  do_log "INFO desk $2 of $1 (${ENV:-?}) lives under $3's state root (do_spl_desk_move, spec 069 8.4; read by $4): skipped as $(id -un), no key minted, no pin offered - $3's reconcile and sidecar serve it"
}

# spl_desk_moved_refuse <workspace> <desk id> <action>: 0 (and one FAIL line on
# stderr) when the desk moved to another user, so <action> must stop before it
# makes a dir, mints or reuses a key, or pins. 1 when the desk is the caller's.
# Why (SPL-4744): on sat 2026-11-03 the owner's go to seat c-002 in a workspace ran
# do_spl_desk_up as the box user with ROOT_KEY_JSON. Only the no-key path
# checked spl_desk_moved_to, so it took the stub key the box user's reconcile
# had minted at 10:06Z and asked the hub to pin it: pin_conflict, while the
# agent user's sidecar served the desk, and c-002 on it, with the pinned key.
spl_desk_moved_refuse() {
  local mv u
  mv="$(spl_desk_moved_to "$1" "$2")" || return 1
  u="${mv%%$'\t'*}"
  do_log "FAIL desk $2 of $1 (${ENV:-?}) lives under $u's state root (do_spl_desk_move): $3 as $(id -un) makes no desk dir and mints or pins no key (a pin of this user's key takes the desk from $u's live sidecar). Run it as $u: sudo -u $u -H bash -c 'cd <checkout>/<org>-<app>-orc && <the same env> ./run -a $3'" >&2
  return 0
}

# spl_desk_action_hop_to <workspace> <desk id>: the user a ./run action on this
# desk must re-run as, 0; 1 when it runs here. A desk that moved (see
# spl_desk_moved_to) is 0700 under its owner, with or without SPOOL_DESK_USER,
# so a box-user caller cannot read it or sign with its key (SPL-4985:
# do_spl_desk_post said "no desk for" on sat's moved csitea desk, n=1 dry run,
# 2026-11-07). SPL_DESK_HOPPED: one hop, never a loop. Under SPOOL_TEST=1 only a
# test's own SPL_DESK_AS_CMD hops: never to a real user.
spl_desk_action_hop_to() {
  local mv
  [[ -z "${SPL_DESK_HOPPED:-}" ]] || return 1
  [[ "${SPOOL_TEST:-}" != 1 || -n "${SPL_DESK_AS_CMD:-}" ]] || return 1
  mv="$(spl_desk_moved_to "$1" "$2")" || return 1
  printf '%s' "${mv%%$'\t'*}"
}

# spl_desk_action_hop <action> <user> <workspace> <desk id> <agent> [var]...:
# <action> again as <user> with its HOME; returns that run's rc. sudo drops the
# environment, so every DESK_* input and each named [var] goes by name (compgen
# -v: a caller's subshell may not export them). SPL_STATE_DIR stays behind: it
# is the caller's state. A DESK_BODY_FILE or DESK_FILES path must be readable by
# <user>; its FATAL names it. Not "action": do_log assigns a variable of that
# name, and through bash's dynamic scope it would become this hop's action.
spl_desk_action_hop() {
  local run_action="$1" u="$2" ws="$3" box="$4" agent="$5" v
  shift 5
  local -a as=() vars=()
  read -r -a as <<<"${SPL_DESK_AS_CMD:-sudo -n -u}"
  while read -r v; do vars+=("$v=${!v:-}"); done < <(compgen -v DESK_)
  for v in "$@"; do vars+=("$v=${!v:-}"); done
  do_log "INFO desk $box of $ws ($ENV) lives under $u's state root (spec 069 8.3.1): $run_action re-runs as $u" >&2
  "${as[@]}" "$u" -- env HOME="$(getent passwd "$u" | cut -d: -f6)" "${vars[@]}" ENV="$ENV" TENANT_ID="$ws" DESK_BOX="$box" DESK_AGENT="$agent" \
    DRY_RUN="${DRY_RUN:-1}" SPOOL_ROOT="${SPOOL_ROOT:-}" SPOOL_BOX_ENV="${SPOOL_BOX_ENV:-}" RUN_STDOUT_IS_DATA="${RUN_STDOUT_IS_DATA:-}" \
    SPL_DESK_HOPPED="$(id -un)" "$PROJ_PATH/run" -a "$run_action" 9>&-
}
