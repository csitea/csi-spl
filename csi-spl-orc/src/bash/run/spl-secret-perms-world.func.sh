#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1957 (owner answer A, poll d1585759): no secret file of
# @description the three classes is open to other local users. The sibling of
# @description do_spl_gcp_secret_perms (one key dir, ACL-aware) for every home:
# @description   - gcp:  a *.json service-account key (has a private_key)
# @description   - ssh:  a file that starts as a PRIVATE KEY
# @description   - qwen: every file under the qwen CLI's state dir
# @description searched under SECRET_PERMS_DIRS of each home. Per file:
# @description other loses every bit (o-rwx); the group loses every bit
# @description (g-rwx) only when it is not the owner's own group (group name
# @description == owner name) and the file has no ACL (a chmod g on an ACL
# @description file moves the mask, SPL-1924). Files only: never a dir, a
# @description symlink, the content, the owner or the name; nothing deleted or
# @description rotated. One row per file it changes, by class, index and age
# @description (never a name or path), then one summary row per class.
# @description Dry run unless DRY_RUN=0.
# @param SECRET_PERMS_HOMES (optional) - default /root and every /home/* dir
# @param SECRET_PERMS_DIRS (optional) - dirs relative to each home, default ".gcp .ssh .qwen"
# @param SECRET_PERMS_UNDO (optional) - on DRY_RUN=0, write "<mode> <path>" per changed file here (mode 600)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DRY_RUN=0 ./run -a do_spl_secret_perms_world
#------------------------------------------------------------------------------
do_spl_secret_perms_world() {
  local apply=1 h
  if spl_dry_run; then apply=0; else local drc=$?; [[ $drc -eq 1 ]] || return 1; fi
  local -a homes=()
  if [[ -n "${SECRET_PERMS_HOMES:-}" ]]; then
    read -ra homes <<<"$SECRET_PERMS_HOMES"
  else
    homes=(/root)
    for h in /home/*; do [[ -d "$h" && ! -L "$h" ]] && homes+=("$h"); done
  fi
  local dirs="${SECRET_PERMS_DIRS:-.gcp .ssh .qwen}" undo="${SECRET_PERMS_UNDO:-}"

  # another user's home is read through sudo; root or a sandbox run goes direct
  local -a run=()
  [[ "$(id -u)" == 0 || -n "${SECRET_PERMS_NO_SUDO:-}" ]] || run=(sudo -n)
  local out rc n
  out="$("${run[@]}" bash -c "$(spl_spw_funcs); spl_spw_scan \"\$@\"" spl-secret-perms-world \
    "$apply" "$dirs" "$undo" "${homes[@]}" </dev/null 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FAIL the secret files are not all closed to other users (exit $rc)"; return 1; }
  n="$(grep -c ' change=yes$' <<<"$out")"
  if (( apply )); then
    do_log "OK the secret files: $n changed, none open to other"
  else
    do_log "OK DRY_RUN the secret files: $n would change. Re-run with DRY_RUN=0 to apply."
  fi
}

# spl_spw_funcs -> the step's definitions, for a bash -c that may run under sudo.
spl_spw_funcs() {
  declare -f spl_spw_scan spl_spw_class spl_spw_target spl_spw_open
}

# spl_spw_class <file> <in the qwen dir 0|1> -> gcp | ssh | qwen, or nothing.
# Greps the file quietly or reads its first bytes; prints no content.
spl_spw_class() {
  local f="$1"
  [[ "$2" == 1 ]] && { echo qwen; return 0; }
  if [[ "$f" == *.json ]] && grep -q '"private_key"' "$f" 2>/dev/null &&
    grep -qE '"type": *"service_account"' "$f" 2>/dev/null; then
    echo gcp; return 0
  fi
  head -c 64 "$f" 2>/dev/null | grep 'PRIVATE KEY' >/dev/null && echo ssh
  return 0
}

# spl_spw_target <file> -> the octal mode the file should have: other none;
# the group none unless it is the owner's own group or the file has an ACL.
spl_spw_target() {
  local f="$1" m u g acl=0
  m="$(stat -c %a "$f")"; u="$(stat -c %U "$f")"; g="$(stat -c %G "$f")"
  if command -v getfacl >/dev/null 2>&1 && getfacl -cp "$f" 2>/dev/null | grep '^mask::' >/dev/null; then acl=1; fi
  m=$(( 8#$m & ~8#7 ))
  (( acl == 0 )) && [[ "$g" != "$u" ]] && m=$(( m & ~8#70 ))
  printf '%o\n' "$m"
}

# spl_spw_open <file> -> 0 when the file is still open: other has a bit, or
# a foreign group (no ACL) has one.
spl_spw_open() {
  [[ "$(spl_spw_target "$1")" != "$(stat -c %a "$1")" ]]
}

# spl_spw_scan <apply> <dirs> <undo file> <home>...: a row per file to change,
# a summary row per class. Exit 1 when a chmod failed or a file is still open.
spl_spw_scan() {
  local apply="$1" dirs="$2" undo="$3" h d f c q now age before after bad=0 i=0
  shift 3
  local -A total=() open=() changed=()
  local -a files=()
  now="$(date +%s)"
  if (( apply )) && [[ -n "$undo" ]]; then
    # a default ACL on the dir beats the umask: drop the ACL, then 600
    (umask 077 && : >"$undo") || return 1
    if command -v setfacl >/dev/null 2>&1; then setfacl -b "$undo" 2>/dev/null; fi
    chmod 600 "$undo" || return 1
  fi
  for h in "$@"; do
    for d in $dirs; do
      [[ -d "$h/$d" && ! -L "$h/$d" ]] || continue
      q=0; [[ "${d##*/}" == .qwen ]] && q=1
      while IFS= read -r -d '' f; do files+=("$q $f"); done < <(find -P "$h/$d" -type f -print0 2>/dev/null | sort -z)
    done
  done
  for f in "${files[@]}"; do
    q="${f%% *}" f="${f#* }"
    c="$(spl_spw_class "$f" "$q")"
    [[ -n "$c" ]] || continue
    total[$c]=$(( ${total[$c]:-0} + 1 ))
    spl_spw_open "$f" || continue
    open[$c]=$(( ${open[$c]:-0} + 1 ))
    i=$((i + 1))
    age=$(( (now - $(stat -c %Y "$f")) / 86400 ))
    before="$(stat -c %a "$f")"; after="$(spl_spw_target "$f")"
    if (( apply )); then
      [[ -n "$undo" ]] && printf '%s %s\n' "$before" "$f" >>"$undo"
      if ! chmod "$after" "$f" || spl_spw_open "$f"; then
        echo "FAIL $c $i age=${age}d is still open after the fix"; bad=1; continue
      fi
    fi
    changed[$c]=$(( ${changed[$c]:-0} + 1 ))
    echo "$c $i age=${age}d mode=$before -> mode=$after change=yes"
  done
  for c in gcp ssh qwen; do
    echo "summary $c files=${total[$c]:-0} open=${open[$c]:-0} changed=${changed[$c]:-0}"
  done
  return "$bad"
}
