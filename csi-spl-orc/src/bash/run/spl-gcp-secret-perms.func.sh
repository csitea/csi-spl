#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1924: no secret in the box owner's GCP key dir is readable
# @description by another local user, and a shared-ACL box keeps the agent
# @description user's read. For every regular file directly in the dir:
# @description   - other: no access; the owner: rw-
# @description   - the owning group and every named ACL entry: at most r--,
# @description     never wider than they read before
# @description   - the ACL mask: r-- when a named entry or the group reads,
# @description     else --- (a mask::--- that cancelled a named entry's read
# @description     is lifted, so that entry reads again, read-only)
# @description The dir itself: no other access, in its default ACL too, so a
# @description new file is not born world-readable. Subdirs and symlinks are
# @description skipped and counted. One before/after row per file, by index
# @description and role (key, overlay, file): the mode and the getfacl -c
# @description entries, never a name or content. Without getfacl the rows
# @description carry the mode only. Dry run unless DRY_RUN=0.
# @description do_spl_private_overlay_pull runs the same step (spl_gsp_fix)
# @description on the file it places.
# @param GCP_KEY_DIR (optional) - default $HOME/.gcp/.csi, do_gcp_account's key dir
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DRY_RUN=0 ./run -a do_spl_gcp_secret_perms
#------------------------------------------------------------------------------
do_spl_gcp_secret_perms() {
  local dir="${GCP_KEY_DIR:-$HOME/.gcp/.csi}" apply=1 real
  if spl_dry_run; then apply=0; else local drc=$?; [[ $drc -eq 1 ]] || return 1; fi
  real="$(readlink -f "$dir" 2>/dev/null)"
  [[ -n "$real" && -d "$real" ]] || { do_log "FATAL GCP_KEY_DIR is not a dir: $dir"; return 1; }

  # the dir's owner or root changes it; anyone else goes through sudo
  local -a run=()
  [[ "$(stat -c %u "$real")" == "$(id -u)" || "$(id -u)" == 0 ]] || run=(sudo -n)
  local out rc n
  out="$("${run[@]}" bash -c "$(spl_gsp_funcs); spl_gsp_scan \"\$@\"" spl-gcp-secret-perms "$real" "$apply" </dev/null 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FAIL the secret permissions in $real are not all fixed (exit $rc)"; return 1; }
  n="$(grep -c ' change=yes$' <<<"$out")"
  if (( apply )); then
    do_log "OK $real: $n row(s) changed, no file open to other"
  else
    do_log "OK DRY_RUN $real: $n row(s) would change. Re-run with DRY_RUN=0 to apply."
  fi
}

# spl_gsp_funcs -> the step's function definitions, for a bash -c that may
# run under sudo (here) or as root (do_spl_private_overlay_pull).
spl_gsp_funcs() {
  declare -f spl_gsp_scan spl_gsp_fix spl_gsp_fix_dir spl_gsp_spec spl_gsp_line spl_gsp_check
}

# spl_gsp_scan <dir> <apply 0|1>: the dir row, one row per regular file, the
# skipped count. Exit 1 when a step failed or a file is still open after it.
spl_gsp_scan() {
  local d="$1" apply="$2" f i=0 role row skipped=0 bad=0
  row="$(spl_gsp_fix_dir "$d" "$apply")" || bad=1
  echo "dir $row"
  for f in "$d"/* "$d"/.[!.]*; do
    [[ -e "$f" || -L "$f" ]] || continue
    if [[ -L "$f" || ! -f "$f" ]]; then skipped=$((skipped + 1)); continue; fi
    i=$((i + 1))
    case "${f##*/}" in csi-spl-private.yaml) role=overlay ;; *.json) role=key ;; *) role="file" ;; esac
    row="$(spl_gsp_fix "$f" "$apply")" || bad=1
    echo "file $i $role $row"
    if (( apply )) && ! spl_gsp_check "$f"; then echo "FAIL file $i $role is still open after the fix"; bad=1; fi
  done
  echo "skipped $skipped (subdirs, symlinks)"
  return "$bad"
}

# spl_gsp_line <path> -> "mode=<octal> acl=<entries, comma-joined>", or
# "mode=<octal>" without getfacl. Permission entries only, never content.
spl_gsp_line() {
  if command -v getfacl >/dev/null 2>&1; then
    echo "mode=$(stat -c %a "$1") acl=$(getfacl -cpE "$1" 2>/dev/null | grep -v '^$' | paste -sd, -)"
  else
    echo "mode=$(stat -c %a "$1")"
  fi
}

# spl_gsp_spec <file> -> the target: "acl <setfacl --set spec>" when the file
# has named ACL entries, else "mode <octal>". The group keeps r only when it
# read before (its entry within the mask); a named entry keeps r only when
# its entry had r; the mask is r-- when either reads, else ---.
spl_gsp_spec() {
  local f="$1" e k p g="" m="" reads=0 named="" mode
  if command -v getfacl >/dev/null 2>&1; then
    for e in $(getfacl -cpE "$f" 2>/dev/null); do
      k="${e%:*}" p="${e##*:}"
      case "$k" in
        group:) g="$p" ;;
        mask:) m="$p" ;;
        user:?* | group:?*)
          if [[ "${p:0:1}" == r ]]; then p="r--"; reads=1; else p="---"; fi
          named+=",${k}:$p" ;;
      esac
    done
  fi
  if [[ -z "$named" ]]; then
    mode="$(stat -c %a "$f")"
    echo "mode 6$(( ${mode: -2:1} & 4 ))0"
    return 0
  fi
  if [[ "${g:0:1}" == r && ( -z "$m" || "${m:0:1}" == r ) ]]; then g="r--"; reads=1; else g="---"; fi
  if (( reads )); then m="r--"; else m="---"; fi
  echo "acl u::rw-${named},g::$g,m::$m,o::---"
}

# spl_gsp_fix <file> <apply 0|1>: the one permission step for a secret file.
# Prints "<before> -> <after> change=yes", or "<before> change=no". With
# apply=0 the after is the target shown on a scratch file; nothing changes.
spl_gsp_fix() {
  local f="$1" apply="$2" before after kind val t
  before="$(spl_gsp_line "$f")"
  read -r kind val <<<"$(spl_gsp_spec "$f")"
  if (( apply )); then
    t="$f"
  else
    t="$(mktemp)" || return 1
  fi
  case "$kind" in
    acl) setfacl --set "$val" "$t" ;;
    mode) chmod "$val" "$t" ;;
  esac || { (( apply )) || rm -f "$t"; return 1; }
  after="$(spl_gsp_line "$t")"
  (( apply )) || rm -f "$t"
  if [[ "$before" == "$after" ]]; then echo "$before change=no"; else echo "$before -> $after change=yes"; fi
}

# spl_gsp_fix_dir <dir> <apply 0|1>: no other access to the dir, nor in its
# default ACL. Prints the row like spl_gsp_fix.
spl_gsp_fix_dir() {
  local d="$1" apply="$2" before after
  before="$(spl_gsp_line "$d")"
  if (( apply )); then
    chmod o= "$d" || return 1
    if command -v getfacl >/dev/null 2>&1 && getfacl -cpd "$d" 2>/dev/null | grep '^other::' >/dev/null; then
      setfacl -d -m o::--- "$d" || return 1
    fi
    after="$(spl_gsp_line "$d")"
  else
    after="$(sed -E -e 's/^mode=([0-7]*)[0-7]( |$)/mode=\10\2/' -e 's/(^|,)other::[rwx-]+/\1other::---/' \
      -e 's/(^|,)default:other::[rwx-]+/\1default:other::---/' <<<"$before")"
  fi
  if [[ "$before" == "$after" ]]; then echo "$before change=no"; else echo "$before -> $after change=yes"; fi
}

# spl_gsp_check <file>: 0 when the owner reads and writes, other has nothing,
# the group class writes and executes nothing, and every named entry with r
# still reads through the mask. 1 for the shapes SPL-1924 found: 674
# (other::r--) and a named entry's read cancelled by mask::---.
spl_gsp_check() {
  local f="$1" mode e p m=""
  mode="$(stat -c %a "$f")"; mode="${mode: -3}"
  [[ "${mode:0:1}" == [67] && "${mode:2:1}" == 0 ]] || return 1
  (( (${mode:1:1} & 3) == 0 )) || return 1
  command -v getfacl >/dev/null 2>&1 || return 0
  m="$(getfacl -cpE "$f" 2>/dev/null | sed -n 's/^mask:://p')"
  for e in $(getfacl -cpE "$f" 2>/dev/null | grep -E '^(user|group):[^:]+:'); do
    p="${e##*:}"
    [[ "${p:0:1}" == r && -n "$m" && "${m:0:1}" != r ]] && return 1
  done
  return 0
}
