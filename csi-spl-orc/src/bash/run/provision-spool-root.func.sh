#!/bin/bash
#------------------------------------------------------------------------------
# @description Make the box's shared spool dir (cnf env.box.spool_root) with
# @description the permissions model documented in all.env.yaml env.box
# @description (spec 017 FR-SEC-001): owned by a dedicated group (cnf
# @description spool_root_group, default spool-agents), mode 27<g><o> derived
# @description from spool_root_other (2770 for the default "---"), setgid,
# @description NOT sticky (an ack renames a message another user wrote), and
# @description ACLs u/g rwx + o <other> on the root and everything in it, with
# @description default ACLs so a later entry inherits them. Files get rw, not x.
# @description Idempotent; re-running repairs drift.
# @description Never creates the group or changes membership: that is
# @description do_repair_spool_root. A missing group leaves an EXISTING root
# @description untouched (WARN, exit 0, so do_setup_app_inf does not break a
# @description live box) and refuses to make a new one.
# @description Needs root for /var: uses `sudo -n` when the caller is not root
# @description and fails with the exact commands when sudo would prompt.
# @description Called by do_setup_app_inf; a box install calls it too.
# @param SPOOL_ROOT_DIR (optional) - override cnf env.box.spool_root
# @param SPOOL_ROOT_GROUP (optional) - override cnf env.box.spool_root_group
# @param SPOOL_ROOT_OTHER (optional) - override cnf env.box.spool_root_other
# @example ./run -a do_provision_spool_root
#------------------------------------------------------------------------------
do_provision_spool_root() {
  do_require_bin setfacl getfacl || return 1
  _spool_root_model || return 1

  if [[ -n "$_SR_GROUP" ]] && ! getent group "$_SR_GROUP" >/dev/null; then
    if [[ -d "$_SR_DIR" ]]; then
      do_log "WARN group $_SR_GROUP does not exist: $_SR_DIR left as is ($(stat -c '%a %U:%G' "$_SR_DIR"))"
      do_log "WARN migrate it in a quiet window: ./run -a do_repair_spool_root (dry run first)"
      return 0
    fi
    do_log "FATAL group $_SR_GROUP does not exist: create it with ./run -a do_repair_spool_root"
    return 1
  fi

  local cmds=()
  mapfile -t cmds < <(_spool_root_perm_cmds)
  _spool_root_run_as_root "${cmds[@]}" || return 1
  _spool_root_verify || return 1
  do_log "OK spool root $_SR_DIR: $(stat -c '%A %U:%G' "$_SR_DIR"), default ACL u/g rwx, o $_SR_OTHER"
}

# _spool_root_model: read cnf + env overrides into _SR_DIR _SR_GROUP _SR_OTHER
# _SR_MODE (the root's octal mode, setgid included) and validate them.
_spool_root_model() {
  do_lde_cnf || return 1
  _SR_DIR="${SPOOL_ROOT_DIR:-$(yq -r '.env.box.spool_root // ""' "$LDE_CNF")}"
  _SR_GROUP="${SPOOL_ROOT_GROUP-$(yq -r '.env.box.spool_root_group // ""' "$LDE_CNF")}"
  _SR_OTHER="${SPOOL_ROOT_OTHER:-$(yq -r '.env.box.spool_root_other // "---"' "$LDE_CNF")}"
  [[ "$_SR_DIR" == /* && "$_SR_DIR" != / ]] || { do_log "FATAL env.box.spool_root must be an absolute path, got: '$_SR_DIR'"; return 1; }
  [[ "$_SR_OTHER" =~ ^[r-][w-][x-]$ ]] || { do_log "FATAL env.box.spool_root_other must look like rwx / ---, got: $_SR_OTHER"; return 1; }
  [[ -z "$_SR_GROUP" || "$_SR_GROUP" =~ ^[a-z_][a-z0-9_-]*$ ]] || { do_log "FATAL env.box.spool_root_group is not a group name: $_SR_GROUP"; return 1; }
  # closing `other` without a shared group locks every agent but the owner out
  [[ "$_SR_OTHER" == rwx || -n "$_SR_GROUP" ]] || { do_log "FATAL spool_root_other '$_SR_OTHER' needs a spool_root_group"; return 1; }
  local o=0
  [[ "${_SR_OTHER:0:1}" == r ]] && o=$((o + 4))
  [[ "${_SR_OTHER:1:1}" == w ]] && o=$((o + 2))
  [[ "${_SR_OTHER:2:1}" == x ]] && o=$((o + 1))
  _SR_MODE="277$o"
}

# _spool_root_perm_cmds: the root-run commands that apply the model, one per
# line. Dirs get rwx for u/g (+ o <other>) and setgid so the group is
# inherited; files get rw for u/g (+ o <other> without x); default ACLs on
# every dir make a later entry inherit the same.
_spool_root_perm_cmds() {
  local d="$_SR_DIR" o="$_SR_OTHER" of="${_SR_OTHER/x/-}"
  echo "mkdir -p '$d'"
  [[ -n "$_SR_GROUP" ]] && echo "chgrp -R '$_SR_GROUP' '$d'"
  echo "chmod $_SR_MODE '$d'"
  echo "chmod -t '$d'"
  echo "find '$d' -mindepth 1 -type d -exec chmod g+s,-t {} +"
  echo "find '$d' -type d -exec setfacl -m u::rwx,g::rwx,o::$o,m::rwx {} +"
  echo "find '$d' -type d -exec setfacl -d -m u::rwx,g::rwx,o::$o,m::rwx {} +"
  echo "find '$d' -type f -exec setfacl -m u::rw-,g::rw-,o::$of,m::rw- {} +"
}

# _spool_root_run_as_root CMD...: run each as root (sudo -n when not root);
# on the first failure print every command for a human to run once.
_spool_root_run_as_root() {
  local c sudo_=()
  (( EUID == 0 )) || sudo_=(sudo -n)
  for c in "$@"; do
    "${sudo_[@]}" bash -c "$c" 2>/dev/null || {
      do_log "FATAL could not run as root: $c"
      do_log "INFO run these once as root, then re-run:"
      printf '    %s\n' "$@"
      return 1
    }
  done
}

# _spool_root_verify: the root carries the model (mode, group, not sticky,
# access + default ACL for other).
_spool_root_verify() {
  local d="$_SR_DIR" acl
  # [[ -k ]] is the sticky test: it must be off (ack renames across users)
  if [[ -k "$d" ]]; then do_log "FATAL $d is still sticky"; return 1; fi
  [[ "$(stat -c %a "$d")" == "$_SR_MODE" ]] || { do_log "FATAL $d mode $(stat -c %a "$d"), want $_SR_MODE"; return 1; }
  [[ -z "$_SR_GROUP" || "$(stat -c %G "$d")" == "$_SR_GROUP" ]] || { do_log "FATAL $d group $(stat -c %G "$d"), want $_SR_GROUP"; return 1; }
  acl="$(getfacl -p "$d" 2>/dev/null)"
  grep -qx "other::$_SR_OTHER" <<<"$acl" || { do_log "FATAL ACL other on $d is not $_SR_OTHER"; return 1; }
  grep -qx "default:other::$_SR_OTHER" <<<"$acl" || { do_log "FATAL default ACL not set on $d"; return 1; }
}
