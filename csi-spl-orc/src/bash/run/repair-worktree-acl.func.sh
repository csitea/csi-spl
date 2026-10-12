#!/bin/bash
#------------------------------------------------------------------------------
# @description Give the agent user write access on a worktree's log dirs.
# @description A named-user ACL of r-x is inherited by every dat/log/bash
# @description under the worktree root and beats the group, so that user
# @description cannot write the pre-push log. This sets u:<user>:rwx and
# @description default d:u:<user>:rwx on the worktree root and on every
# @description existing */dat/log/bash directory, and u:<user>:rw on the
# @description .log files directly in those directories.
# @description The user is SPOOL_AGENT_USER, else that key in the box env
# @description (SPOOL_BOX_ENV, else $SPOOL_ROOT/box.env): the same name the
# @description spawn scripts resolve. The root is WORKTREE_DIR, the var
# @description those scripts use, else the worktree parent beside the main
# @description checkout (<checkout>-wt). No user or path is hardcoded.
# @description DRY_RUN=1 (the default) prints how many paths it would set
# @description and changes nothing. DRY_RUN=0 applies. Idempotent.
# @description The spool-root provision and repair do not fit: they own the
# @description spool dir's group model, not worktree logs.
# @param WORKTREE_DIR (optional) - the worktree root; default <checkout>-wt
# @param SPOOL_AGENT_USER (optional) - the agent OS user; else the box env
# @param DRY_RUN (optional) - 1 (default) count only, 0 apply
# @example ./run -a do_repair_worktree_acl
# @example DRY_RUN=0 SPOOL_AGENT_USER=<HARNESS_USER> WORKTREE_DIR=<WORKTREE_ROOT> ./run -a do_repair_worktree_acl
#------------------------------------------------------------------------------
do_repair_worktree_acl() {
  do_require_bin setfacl getfacl || return 1
  local dry="${DRY_RUN:-1}" user root
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 1; }
  _wt_acl_user || return 1
  _wt_acl_root || return 1
  user="$_WT_USER"
  root="$_WT_ROOT"
  [[ "$root" == /* && "$root" != / ]] || { do_log "FATAL WORKTREE_DIR must be an absolute path other than /, got: '$root'"; return 1; }
  [[ -d "$root" ]] || { do_log "FATAL worktree root does not exist: $root"; return 1; }

  local -a dirs=() files=()
  local d f n list rc=0
  dirs+=("$root")
  list="$(mktemp)" || { do_log "FATAL mktemp failed"; return 1; }
  find "$root" -mindepth 1 -type d -regextype posix-extended -regex '.*/dat/log/bash$' -print0 >"$list"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$list"
    do_log "FATAL find failed under $root"
    return 1
  fi
  while IFS= read -r -d '' d; do
    dirs+=("$d")
  done <"$list"
  find "$root" -type f -regextype posix-extended -regex '.*/dat/log/bash/[^/]+\.log$' -print0 >"$list"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "$list"
    do_log "FATAL find failed under $root"
    return 1
  fi
  while IFS= read -r -d '' f; do
    files+=("$f")
  done <"$list"
  rm -f "$list"

  n=$(( ${#dirs[@]} + ${#files[@]} ))
  do_log "INFO would set u:${user}:rwx (+ default) on ${#dirs[@]} dir(s) and u:${user}:rw on ${#files[@]} log file(s) under $root"
  if [[ "$dry" == 1 ]]; then
    do_log "OK dry run: would set ${n} path(s); nothing changed"
    return 0
  fi

  for d in "${dirs[@]}"; do
    _wt_acl_set "$d" "u:${user}:rwx" "d:u:${user}:rwx" "$user" || return 1
  done
  if ((${#files[@]})); then
    for f in "${files[@]}"; do
      _wt_acl_set "$f" "u:${user}:rw" "" "$user" || return 1
    done
  fi
  do_log "OK worktree ACL: set ${n} path(s) under $root for ${user}"
}

# _wt_acl_set PATH ENTRY [ENTRY2] USER: setfacl -m the entries. A path the
# agent user already owns needs no named entry for that user (the owner
# class grants the write), and the caller often cannot change it. Any other
# failure is fatal.
_wt_acl_set() {
  local path="$1" a="$2" b="${3:-}" user="$4" owner args=()
  args=(-m "$a")
  [[ -n "$b" ]] && args+=(-m "$b")
  if setfacl "${args[@]}" "$path" 2>/dev/null; then
    return 0
  fi
  owner="$(stat -c %U "$path" 2>/dev/null || true)"
  if [[ "$owner" == "$user" ]]; then
    do_log "INFO $path is owned by ${user}: left as is"
    return 0
  fi
  do_log "FATAL setfacl on $path (owner ${owner:-unknown})"
  return 1
}

# _wt_acl_user: SPOOL_AGENT_USER, else the box env the spawn scripts read.
# Sets _WT_USER. Refuses an empty value, a non-name, or an unknown user.
_wt_acl_user() {
  local u="${SPOOL_AGENT_USER:-}" f
  if [[ -z "$u" ]]; then
    if [[ -n "${SPOOL_BOX_ENV:-}" ]]; then
      f="$SPOOL_BOX_ENV"
    elif [[ -n "${SPOOL_ROOT:-}" ]]; then
      f="${SPOOL_ROOT}/box.env"
    else
      f=""
    fi
    if [[ -n "$f" && -r "$f" ]]; then
      u="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$f" | tail -1 | tr -d "\"'\r")"
    fi
  fi
  [[ -n "$u" ]] || { do_log "FATAL SPOOL_AGENT_USER is empty: set it, or the box env (SPOOL_BOX_ENV or SPOOL_ROOT/box.env)"; return 1; }
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || { do_log "FATAL SPOOL_AGENT_USER is not an OS user name: $u"; return 1; }
  id -u "$u" >/dev/null 2>&1 || { do_log "FATAL SPOOL_AGENT_USER: no such OS user: $u"; return 1; }
  _WT_USER="$u"
}

# _wt_acl_root: WORKTREE_DIR, else <main checkout>-wt, the parent the spawn
# scripts build WORKTREE_DIR from (REPO-wt/<id>). Sets _WT_ROOT.
_wt_acl_root() {
  local root="${WORKTREE_DIR:-}" app
  if [[ -z "$root" ]]; then
    app="$(_do_oap_canonical_app_path)"
    [[ -n "$app" && "$app" == /* && "$app" != / ]] || {
      do_log "FATAL WORKTREE_DIR is empty and the checkout path does not resolve"; return 1; }
    root="${app}-wt"
  fi
  _WT_ROOT="$root"
}
