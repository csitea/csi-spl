#!/bin/bash
#------------------------------------------------------------------------------
# spec 108 3.5: one box = one workspace. A box enrolled by
# do_spl_box_workspace_setup carries ONE workspace:
#   <base>/claim           box-wide, root-owned: the one workspace slug
#   <base>/<tenant>/       0700, owned by that workspace's OS user (its home)
#   <base>/<tenant>/spool  the workspace's spool root (box.env names the user)
#   <base>/<tenant>/state  the workspace's state dir (SPL_STATE_DIR parent)
# Another workspace's OS user gets EACCES on all of it. A box with no claim is
# an operator box (owner Q2: the multi-workspace desk stays operator-only and
# is not isolated from the operator) and every desk action behaves as before.
#   base:   SPL_WS_BASE > cnf env.box.workspace_base
#   user:   SPL_WS_USER > SPL_WS_USER_PREFIX / cnf env.box.workspace_user_prefix
#           + <tenant>
# Under SPOOL_TEST=1 the cnf base is never read: a test sees only the
# SPL_WS_BASE it names, so the box it runs on cannot change its verdict.
#------------------------------------------------------------------------------

# spl_box_ws_cnf <key>: env.box.<key> of all.env.yaml under <ENV>.env.yaml.
# Read straight from the cnf files: the guard runs before do_spl_desk_cnf,
# because it picks the state dir that resolver writes into.
spl_box_ws_cnf() {
  local proj dir
  proj="$(basename "${PROJ_PATH:-}")"
  [[ "$proj" =~ ^([a-z]+)-([a-z]+)-orc$ ]] || return 0
  dir="${APP_PATH:-}/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-cnf/${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  local -a files=("$dir/all.env.yaml")
  [[ -f "${files[0]}" ]] || return 0
  [[ -n "${ENV:-}" && -f "$dir/$ENV.env.yaml" ]] && files+=("$dir/$ENV.env.yaml")
  yq eval-all -r ". as \$i ireduce ({}; . * \$i) | .env.box.$1 // \"\"" "${files[@]}" 2>/dev/null
}

# spl_box_ws_base: the enrolment base dir, or nothing.
spl_box_ws_base() {
  if [[ -n "${SPL_WS_BASE:-}" ]]; then printf '%s' "$SPL_WS_BASE"; return 0; fi
  [[ "${SPOOL_TEST:-}" == 1 ]] && return 0
  spl_box_ws_cnf workspace_base
}

# spl_box_ws_claim: the workspace this box belongs to, or nothing (operator box).
spl_box_ws_claim() {
  local b; b="$(spl_box_ws_base)"
  [[ -n "$b" && -s "$b/claim" ]] || return 0
  head -n 1 "$b/claim" | tr -d '[:space:]'
}

# spl_box_ws_user <tenant>: the workspace's OS user name.
spl_box_ws_user() {
  local u="${SPL_WS_USER:-}"
  [[ -n "$u" ]] || u="${SPL_WS_USER_PREFIX-$(spl_box_ws_cnf workspace_user_prefix)}$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    { do_log "FATAL workspace OS user '$u' is not a user name of at most 32 chars: set SPL_WS_USER"; return 1; }
  printf '%s' "$u"
}

# spl_box_ws_guard <tenant>: the one-box-one-workspace gate of the desk
# actions. Operator box: 0, nothing set. Box claimed by <tenant>: the caller
# must be the workspace's OS user (the owner of <base>/<tenant>), and
# SPL_STATE_DIR defaults to <base>/<tenant>/state/<env>; SPL_WS_SPOOL_ROOT is
# the workspace's spool root. Claimed by another workspace: FATAL, 1.
spl_box_ws_guard() {
  local tenant="$1" b claim owner me
  SPL_WS_SPOOL_ROOT=""
  claim="$(spl_box_ws_claim)"
  [[ -n "$claim" ]] || return 0
  b="$(spl_box_ws_base)"
  if [[ "$claim" != "$tenant" ]]; then
    do_log "FATAL this box belongs to workspace '$claim' ($b/claim): one box = one workspace (spec 108 3.5), refusing '$tenant'"
    return 1
  fi
  owner="$(stat -c %U "$b/$tenant" 2>/dev/null)" ||
    { do_log "FATAL $b/$tenant is missing: re-run do_spl_box_workspace_setup for '$tenant'"; return 1; }
  me="$(id -un)"
  [[ "$me" == "$owner" ]] ||
    { do_log "FATAL workspace '$tenant' runs as its own OS user '$owner', not '$me' (sudo -u $owner)"; return 1; }
  if [[ -n "${SPL_STATE_DIR:-}" && "$SPL_STATE_DIR" != "$b/$tenant/state/"* ]]; then
    do_log "FATAL SPL_STATE_DIR=$SPL_STATE_DIR is outside workspace '$tenant' ($b/$tenant/state)"; return 1
  fi
  SPL_STATE_DIR="${SPL_STATE_DIR:-$b/$tenant/state/${ENV:-}}"
  SPL_WS_SPOOL_ROOT="$b/$tenant/spool"
  export SPL_STATE_DIR SPL_WS_SPOOL_ROOT
}
