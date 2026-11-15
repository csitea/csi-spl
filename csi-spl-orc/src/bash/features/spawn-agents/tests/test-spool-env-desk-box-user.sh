#!/usr/bin/env bash
# spool_env_resolve: the desk sidecar's box user is the owner of the box's
# fleet root (SPOOL_FLEET_ROOT), not of its own SPOOL_ROOT, the desk spool
# (SPL-5609).
#
# Why: the desk sidecar (spl-desk-up) runs spool-notify.sh with SPOOL_ROOT =
# the desk spool. Since the desks moved to their own OS user (spec 069 8.3)
# that spool is owned by the desk user, while the agents' panes live on the
# box user's tmux. With no SPOOL_BOX_USER in its env, the notifier took the
# desk spool's owner, looked in the desk user's tmux and found no pane: a
# topic seat was never typed its owner's posts, measured on prd 2026-11-14
# (3 of 3 posts in the seat's own topic, each in the desk inbox within
# 0.2 s, none typed).
#
# The owners are faked with a `stat` function: a test cannot chown.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox

. "$T_FEAT/lib/spool-env.inc.sh"

FLEET="$T_TMP/fleet"; DESK="$T_TMP/desk/acme/box1/spool"
mkdir -p "$FLEET" "$DESK"
stat() {  # -c %U PATH -> the faked owner of PATH
  case "${*: -1}" in
    "$FLEET") echo boxuser ;;
    "$DESK")  echo deskuser ;;
    *)        command stat "$@" ;;
  esac
}

resolve_box_user() {  # SPOOL_ROOT [SPOOL_FLEET_ROOT] -> the resolved SPOOL_BOX_USER
  (
    unset SPOOL_BOX_USER SPOOL_FLEET_ROOT SPOOL_BOX_ENV
    export SPOOL_ROOT="$1"
    [ -n "${2:-}" ] && export SPOOL_FLEET_ROOT="$2"
    SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1
    printf '%s' "$SPOOL_BOX_USER"
  )
}

eq "the desk sidecar (SPOOL_ROOT = desk spool, SPOOL_FLEET_ROOT given) takes the fleet root's owner" \
  boxuser "$(resolve_box_user "$DESK" "$FLEET")"
eq "CONTROL: a harness call with no SPOOL_FLEET_ROOT keeps its SPOOL_ROOT's owner" \
  boxuser "$(resolve_box_user "$FLEET")"
eq "CONTROL: a desk with no fleet root given keeps the desk spool's owner" \
  deskuser "$(resolve_box_user "$DESK")"
eq "CONTROL: a SPOOL_FLEET_ROOT that is no directory is ignored" \
  deskuser "$(resolve_box_user "$DESK" "$T_TMP/no-such-fleet")"
got="$(unset SPOOL_FLEET_ROOT; SPOOL_ROOT="$DESK" SPOOL_FLEET_ROOT="$FLEET" SPOOL_BOX_USER=pinned \
  bash -c '. "$1/lib/spool-env.inc.sh"; SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1; printf %s "$SPOOL_BOX_USER"' _ "$T_FEAT")"
eq "CONTROL: an explicit SPOOL_BOX_USER always wins" pinned "$got"

t_done
