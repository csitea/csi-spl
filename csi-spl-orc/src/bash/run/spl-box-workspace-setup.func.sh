#!/bin/bash
#------------------------------------------------------------------------------
# @description Enrol THIS box into ONE workspace (spec 108 3.5 and 4(d)): one
# @description box = one workspace. It makes, as root (sudo -n):
# @description   1. the workspace's own OS user (cnf
# @description      env.box.workspace_user_prefix + <tenant>), a system user
# @description      whose home is <base>/<tenant> (base: cnf
# @description      env.box.workspace_base)
# @description   2. <base>/<tenant> 0700 owned by that user, holding spool/
# @description      (the workspace's spool root; its box.env names the agent
# @description      user) and state/ (the desk state dir of every ENV)
# @description   3. the box-wide claim <base>/claim (root-owned, 0644): the
# @description      one workspace slug. do_spl_desk_up and do_spl_desk_pin read
# @description      it and refuse any other workspace on this box.
# @description A box already claimed by ANOTHER workspace, or whose base holds
# @description another workspace's dir, is refused (exit 3): a second
# @description workspace needs another machine. Idempotent for the same one.
# @description Seating a desk afterwards runs as the workspace user; the
# @description action prints that line. Dry run unless DRY_RUN=0.
# @param TENANT_ID - required: the workspace slug this box belongs to
# @param SPL_WS_BASE (optional) - override cnf env.box.workspace_base
# @param SPL_WS_USER (optional) - override the derived workspace OS user
# @param SPL_WS_USER_PREFIX (optional) - override cnf env.box.workspace_user_prefix
# @param DRY_RUN (optional) - 1 (default) or 0
# @example TENANT_ID=acme ./run -a do_spl_box_workspace_setup
# @example TENANT_ID=acme DRY_RUN=0 ./run -a do_spl_box_workspace_setup
#------------------------------------------------------------------------------
do_spl_box_workspace_setup() {
  local tenant="${TENANT_ID:-}" dry=1 b u claim
  spl_require_tenant_slug "$tenant" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  b="$(spl_box_ws_base)"
  [[ "$b" == /* && "$b" != / ]] || { do_log "FATAL the workspace base must be an absolute path (cnf env.box.workspace_base or SPL_WS_BASE), got: '$b'"; return 1; }
  u="$(spl_box_ws_user "$tenant")" || return 1
  claim="$(spl_box_ws_claim)"
  if [[ -n "$claim" && "$claim" != "$tenant" ]]; then
    do_log "FATAL this box already belongs to workspace '$claim' ($b/claim): one box = one workspace, refusing '$tenant'"
    return 3
  fi
  local other
  other="$(spl_box_ws_others "$b" "$tenant")"
  [[ -z "$other" ]] || { do_log "FATAL $b already holds workspace dir(s): $other; refusing '$tenant'"; return 3; }

  local -a cmds=()
  mapfile -t cmds < <(spl_box_ws_setup_cmds "$b" "$tenant" "$u")
  if (( dry )); then
    do_log "INFO DRY_RUN would run as root:"; printf '    %s\n' "${cmds[@]}"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to enrol this box into '$tenant'."
    return 0
  fi
  _spool_root_run_as_root "${cmds[@]}" || return 1
  spl_box_ws_verify "$b" "$tenant" "$u" || return 1
  do_log "OK this box belongs to workspace '$tenant': user $u, spool root $b/$tenant/spool, state $b/$tenant/state"
  do_log "OK seat a desk as that user: sudo -u $u env ENV=<env> TENANT_ID=$tenant DESK_AGENT=<id> ROOT_KEY_JSON=<file> DRY_RUN=0 ./run -a do_spl_desk_up"
}

# spl_box_ws_others <base> <tenant>: the workspace dirs under base other than
# tenant's, space-separated (lost+found and dot entries are not workspaces).
spl_box_ws_others() {
  local b="$1" t="$2" e n out=""
  for e in "$b"/*/; do
    [[ -d "$e" ]] || continue
    n="${e%/}"; n="${n##*/}"
    [[ "$n" == "$t" || "$n" == lost+found ]] && continue
    out+="${out:+ }$n"
  done
  printf '%s' "$out"
}

# spl_box_ws_setup_cmds <base> <tenant> <user>: the root commands, one a line.
spl_box_ws_setup_cmds() {
  local b="$1" t="$2" u="$3" w="$1/$2"
  echo "mkdir -p '$b' && chown root:root '$b' && chmod 0755 '$b'"
  echo "getent passwd '$u' >/dev/null || useradd --system --user-group --home-dir '$w' --no-create-home --shell /bin/bash '$u'"
  echo "mkdir -p '$w/spool' '$w/state'"
  echo "[ -e '$w/spool/box.env' ] || printf 'SPOOL_AGENT_USER=%s\nSPOOL_FLEET_TENANT=%s\n' '$u' '$t' >'$w/spool/box.env'"
  echo "chown -R '$u:$u' '$w' && chmod 0700 '$w' '$w/spool' '$w/state'"
  echo "printf '%s\n' '$t' >'$b/claim.tmp' && chmod 0644 '$b/claim.tmp' && mv -f '$b/claim.tmp' '$b/claim'"
}

# spl_box_ws_verify <base> <tenant> <user>: the enrolment holds.
spl_box_ws_verify() {
  local b="$1" t="$2" u="$3" d got
  local -a as_root=()
  (( EUID == 0 )) || as_root=(sudo -n)
  for d in "$b/$t" "$b/$t/spool" "$b/$t/state"; do
    got="$("${as_root[@]}" stat -c '%a %U' "$d" 2>/dev/null)"
    [[ "$got" == "700 $u" ]] || { do_log "FATAL $d is '$got', want '700 $u'"; return 1; }
  done
  [[ "$(spl_box_ws_claim)" == "$t" ]] || { do_log "FATAL $b/claim does not name '$t'"; return 1; }
}
