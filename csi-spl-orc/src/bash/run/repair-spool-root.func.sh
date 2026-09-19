#!/bin/bash
#------------------------------------------------------------------------------
# @description Migrate an EXISTING box spool root to the 017 FR-SEC-001 model
# @description (the one do_provision_spool_root applies): create the group
# @description (cnf env.box.spool_root_group, default spool-agents) when it is
# @description missing, add every OS user that runs an agent or reads the spool
# @description (SPOOL_ROOT_MEMBERS, the box owner too), re-group the whole
# @description tree, setgid every dir, apply the ACL model (o <other>, default
# @description "---"), then verify: mode, group, not sticky, and an outsider
# @description (`nobody`) can neither list the root nor write into it.
# @description DRY_RUN=1 (the default) prints the current state and the exact
# @description plan and changes nothing. DRY_RUN=0 runs it as root (sudo -n).
# @description A running process keeps the groups it started with: after
# @description DRY_RUN=0 every member restarts its agents / re-logs in, or it
# @description loses the spool. So run it in a QUIET WINDOW (no agent live).
# @param SPOOL_ROOT_MEMBERS (required unless every member is already in the group) - OS users to add, space separated
# @param DRY_RUN (optional) - 1 (default) plan only, 0 apply
# @param SPOOL_ROOT_DIR / SPOOL_ROOT_GROUP / SPOOL_ROOT_OTHER (optional) - override cnf env.box
# @example ./run -a do_repair_spool_root
# @example DRY_RUN=0 SPOOL_ROOT_MEMBERS="<HARNESS_USER> <DEV_USER>" ./run -a do_repair_spool_root
#------------------------------------------------------------------------------
do_repair_spool_root() {
  do_require_bin setfacl getfacl getent || return 1
  _spool_root_model || return 1
  local dry="${DRY_RUN:-1}" g="$_SR_GROUP" u plan=() cmds=() members=()
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 1; }
  [[ -n "$g" ]] || { do_log "FATAL env.box.spool_root_group is empty: nothing to migrate to"; return 1; }
  read -r -a members <<<"${SPOOL_ROOT_MEMBERS:-}"
  for u in "${members[@]}"; do
    id -u "$u" >/dev/null 2>&1 || { do_log "FATAL SPOOL_ROOT_MEMBERS: no such OS user: $u"; return 1; }
  done

  if [[ -d "$_SR_DIR" ]]; then
    do_log "INFO now: $_SR_DIR $(stat -c '%a %U:%G' "$_SR_DIR") other=$(getfacl -p "$_SR_DIR" 2>/dev/null | sed -n 's/^other:://p') default-other=$(getfacl -p "$_SR_DIR" 2>/dev/null | sed -n 's/^default:other:://p')"
  else
    do_log "INFO now: $_SR_DIR does not exist"
  fi

  getent group "$g" >/dev/null || plan+=("groupadd --system '$g'")
  for u in "${members[@]}"; do
    id -nG "$u" | tr ' ' '\n' | grep -qx "$g" || plan+=("usermod -aG '$g' '$u'")
  done
  if ! getent group "$g" >/dev/null && (( ${#members[@]} == 0 )); then
    do_log "FATAL group $g is new: name its members, SPOOL_ROOT_MEMBERS=\"<user> ...\" (every agent OS user and the box owner)"
    return 1
  fi
  mapfile -t cmds < <(_spool_root_perm_cmds)
  plan+=("${cmds[@]}")

  do_log "INFO plan (as root), group $g, root mode $_SR_MODE, other '$_SR_OTHER':"
  printf '    %s\n' "${plan[@]}"
  do_log "INFO afterwards every member restarts its agents / re-logs in to pick up group $g"
  if [[ "$dry" == 1 ]]; then
    do_log "OK dry run: nothing changed; apply with DRY_RUN=0 in a quiet window"
    return 0
  fi

  _spool_root_run_as_root "${plan[@]}" || return 1
  _spool_root_verify || return 1
  _spool_root_outsider_denied || return 1
  do_log "OK spool root $_SR_DIR migrated: $(stat -c '%A %U:%G' "$_SR_DIR"); members of $g: $(getent group "$g" | cut -d: -f4)"
  do_log "INFO now restart every agent of: $(getent group "$g" | cut -d: -f4)"
}

# _spool_root_outsider_denied: `nobody` (in no agent group) can neither list
# the root nor create a file in it. Needs sudo -n; skipped (WARN) without it.
_spool_root_outsider_denied() {
  local sudo_=()
  (( EUID == 0 )) || sudo_=(sudo -n)
  "${sudo_[@]}" true 2>/dev/null || { do_log "WARN no sudo -n: outsider probe skipped"; return 0; }
  if [[ "$_SR_OTHER" == *r* || "$_SR_OTHER" == *w* ]]; then
    do_log "WARN other is '$_SR_OTHER': the spool stays open to outsiders by config"; return 0
  fi
  if "${sudo_[@]}" -u nobody ls "$_SR_DIR" >/dev/null 2>&1; then
    do_log "FATAL outsider (nobody) can list $_SR_DIR"; return 1
  fi
  if "${sudo_[@]}" -u nobody sh -c ": >'$_SR_DIR/.outsider-probe'" 2>/dev/null; then
    "${sudo_[@]}" rm -f "$_SR_DIR/.outsider-probe"
    do_log "FATAL outsider (nobody) can write into $_SR_DIR"; return 1
  fi
}
