#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the watchdog crontab starter
# @description (spec 102 10.4.1, 15.6): TWO lines in the box user's crontab,
# @description `* * * * *` (tag `# <org>-<app>:wd-start`) and `@reboot` (tag
# @description `# <org>-<app>:wd-start-boot`), each running ONLY the
# @description watchdogs' own start command do_spl_wd_inst_start ("start the
# @description missing instances of 1..3"). Installing them drops the 093
# @description keeper line (`# <org>-<app>:wd-ensure`): no separate keeper.
# @description WD_CRON_KIND=ensure installs that legacy keeper line instead
# @description (spec 093 section 6, do_spl_wd_ensure), as before. Every tag is
# @description matched EXACTLY at the end of the line; idempotent (a tagged
# @description line is replaced in place, never appended). The lines point at
# @description the same self-updating checkout as the desk reconcile
# @description (<shared checkout>-desk-cron, DESK_CRON_SRC overrides; an agent
# @description worktree is refused). No fetch on the lines: a fetch every
# @description minute buys nothing the desk reconcile's five-minute one does
# @description not. Spec 068 section 8.1 is applied to THESE lines only. Other
# @description crontab lines belong to other jobs and do not block the install.
# @description A line whose script is outside a checkout is still refused. The
# @description watchdogs run this action themselves when a starter line is
# @description missing (spl_wd_cron_heal). Dry run unless DRY_RUN=0 (prints
# @description the crontab diff).
# @param WD_CRON_ACTION (optional) - install (default) | remove | check
# @param WD_CRON_KIND (optional) - start (default: the 102 starter) | ensure (the 093 keeper line)
# @param CRON_REMOVE (optional) - 1 = WD_CRON_ACTION=remove
# @param WD_ENSURE_WATCH_DRY (optional) - 0 or 1, copied onto the line(s).
# @param   Unset: the line sets nothing and the watchdogs act. 1: they only
# @param   observe (no ring, no takeover): WD_INST_DRY for the starter,
# @param   WD_ENSURE_WATCH_DRY for the keeper.
# @param WD_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/wd
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_wd_ensure_install_cron
# @example DRY_RUN=0 ./run -a do_spl_wd_ensure_install_cron
# @example WD_ENSURE_WATCH_DRY=1 DRY_RUN=0 ./run -a do_spl_wd_ensure_install_cron
# @example WD_CRON_ACTION=check ./run -a do_spl_wd_ensure_install_cron
# @example WD_CRON_KIND=ensure DRY_RUN=0 ./run -a do_spl_wd_ensure_install_cron
#------------------------------------------------------------------------------
declare -F spl_desk_cron_render >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"

# spl_peer_cron_8_1 is the acceptance check. Sourced on use, not at load.
spl_wd_cron_8_1() {
  declare -F spl_peer_cron_8_1 >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-crons.func.sh"
  spl_peer_cron_8_1 "$1"
}

spl_wd_cron_script_of() {
  declare -F spl_peer_cron_script_of >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/spl-peer-crons.func.sh"
  spl_peer_cron_script_of "$1"
}

# SPL_WD_CRON_TAG / _LINE / _SCRIPT / _LOGDIR / _NAME, and the arrays
# SPL_WD_CRON_TAGS / SPL_WD_CRON_LINES: every tagged line this kind owns
# (an empty line = the tag is taken out). No per-minute git fetch.
spl_wd_cron_prep() {
  local trunk="${DESK_CRON_TRUNK:-master}" kind="${WD_CRON_KIND:-start}"
  local path="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "${PROJ_PATH:-csi-spl-orc}")}"
  SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  [[ "$kind" == start || "$kind" == ensure ]] || { do_log "FATAL WD_CRON_KIND must be start or ensure, got: '$kind'"; return 1; }
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  local watch=""
  if [[ -n "${WD_ENSURE_WATCH_DRY:-}" ]]; then
    [[ "$WD_ENSURE_WATCH_DRY" == 0 || "$WD_ENSURE_WATCH_DRY" == 1 ]] ||
      { do_log "FATAL WD_ENSURE_WATCH_DRY must be 0 or 1, got: '$WD_ENSURE_WATCH_DRY'"; return 1; }
  fi
  spl_desk_cron_src || return 1
  SPL_WD_CRON_SCRIPT="$SPL_DESK_CRON_SRC/$SPL_ORG_APP-orc/run"
  SPL_WD_CRON_LOGDIR="${WD_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/wd}"
  if [[ "$kind" == ensure ]]; then
    [[ -n "${WD_ENSURE_WATCH_DRY:-}" ]] && watch="WD_ENSURE_WATCH_DRY=$WD_ENSURE_WATCH_DRY "
    SPL_WD_CRON_NAME=wd-ensure
    SPL_WD_CRON_TAG="$SPL_ORG_APP:wd-ensure"
    SPL_WD_CRON_LINE="* * * * * $path ${watch}$SPL_WD_CRON_SCRIPT -a do_spl_wd_ensure >> $SPL_WD_CRON_LOGDIR/ensure.out 2>&1 # $SPL_WD_CRON_TAG"
    SPL_WD_CRON_TAGS=("$SPL_WD_CRON_TAG")
    SPL_WD_CRON_LINES=("$SPL_WD_CRON_LINE")
    return 0
  fi
  [[ -n "${WD_ENSURE_WATCH_DRY:-}" ]] && watch="WD_INST_DRY=$WD_ENSURE_WATCH_DRY "
  local cmd="$path ${watch}$SPL_WD_CRON_SCRIPT -a do_spl_wd_inst_start >> $SPL_WD_CRON_LOGDIR/starter.out 2>&1"
  SPL_WD_CRON_NAME=wd-start
  SPL_WD_CRON_TAG="$SPL_ORG_APP:wd-start"
  SPL_WD_CRON_LINE="* * * * * $cmd # $SPL_WD_CRON_TAG"
  SPL_WD_CRON_TAGS=("$SPL_WD_CRON_TAG" "$SPL_ORG_APP:wd-start-boot" "$SPL_ORG_APP:wd-ensure")
  local gate; gate="$(spl_cron_boot_gate "$SPL_WD_CRON_LOGDIR/starter.out" "$SPL_WD_CRON_SCRIPT" "$SPL_ORG_APP:wd-start-boot")" || return 1
  SPL_WD_CRON_LINES=("$SPL_WD_CRON_LINE" "@reboot $gate$cmd # $SPL_ORG_APP:wd-start-boot" "")
  return 0
}

# stdin -> stdout: every tag of SPL_WD_CRON_TAGS set to its line (LINES), or
# to nothing when ALL=empty (the remove).
spl_wd_cron_render_all() {
  local all="${1:-set}" i tmp in out
  tmp="$(mktemp -d)" || return 1
  cat > "$tmp/0"
  in="$tmp/0"
  for i in "${!SPL_WD_CRON_TAGS[@]}"; do
    out="$tmp/$((i + 1))"
    if [[ "$all" == empty ]]; then spl_desk_cron_render "${SPL_WD_CRON_TAGS[$i]}" "" < "$in" > "$out"
    else spl_desk_cron_render "${SPL_WD_CRON_TAGS[$i]}" "${SPL_WD_CRON_LINES[$i]}" < "$in" > "$out"; fi
    in="$out"
  done
  cat "$in"
  rm -rf "$tmp"
}

# spl_wd_cron_rendered OUT [empty]: the crontab with this kind's lines set
# (or all taken out). A missing crontab reads as empty.
spl_wd_cron_rendered() {
  { crontab -l 2>/dev/null || true; } | spl_wd_cron_render_all "${2:-set}" > "$1"
}

# 8.1 on this kind's lines only. Other lines are other jobs.
spl_wd_cron_gate() {
  local tmp rc=0 out t
  tmp="$(mktemp)" || return 1
  for t in "${SPL_WD_CRON_TAGS[@]}"; do grep -E " # ${t}$" "$1" || true; done > "$tmp"
  if [[ -s "$tmp" ]]; then
    out="$(spl_wd_cron_8_1 "$tmp")" || rc=$?
  else
    out="OK 8.1 0 command line(s), 0 failing"
  fi
  rm -f "$tmp"
  echo "---- spec 068 8.1 on the $SPL_WD_CRON_NAME line(s):"
  printf '%s\n' "$out" | sed 's/^/    /'
  return "$rc"
}

spl_wd_cron_diff() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  { crontab -l 2>/dev/null || true; } > "$tmp/before"
  spl_wd_cron_render_all "${1:-set}" < "$tmp/before" > "$tmp/after"
  echo "    crontab diff (before -> after):"
  diff -u --label before --label after "$tmp/before" "$tmp/after" | sed 's/^/    /' || true
  if cmp -s "$tmp/before" "$tmp/after"; then echo "    (no change)"; fi
  rm -rf "$tmp"
}

# Every line of this kind installed, each naming an executable script.
spl_wd_cron_check() {
  local i current ran rc=0 differ=0
  for i in "${!SPL_WD_CRON_TAGS[@]}"; do
    [[ -n "${SPL_WD_CRON_LINES[$i]}" ]] || continue
    current="$(spl_desk_cron_line "${SPL_WD_CRON_TAGS[$i]}")"
    if [[ -z "$current" ]]; then
      do_log "FAIL $SPL_WD_CRON_NAME is NOT installed (no line tagged ${SPL_WD_CRON_TAGS[$i]})"; rc=1; continue
    fi
    spl_desk_cron_say "$current"
    ran="$(spl_wd_cron_script_of "$current")"
    [[ -n "$ran" && -x "$ran" ]] || { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; rc=1; continue; }
    [[ "$current" == "${SPL_WD_CRON_LINES[$i]}" ]] || differ=1
  done
  (( rc == 0 )) || return 1
  (( differ )) && do_log "INFO installed with other settings than this call would write - working"
  do_log "OK $SPL_WD_CRON_NAME is installed and its script is executable"
  return 0
}

# Dry run: the diff and the 8.1 check, nothing written. Non-zero when 8.1 fails.
spl_wd_cron_dry() {
  local act="$1" mode=set tmp rc=0
  [[ "$act" == remove ]] && mode=empty
  tmp="$(mktemp -d)" || return 1
  spl_wd_cron_rendered "$tmp/after" "$mode"
  spl_wd_cron_diff "$mode"
  spl_wd_cron_gate "$tmp/after" || rc=$?
  rm -rf "$tmp"
  if (( rc != 0 )); then
    do_log "FATAL the crontab after fails spec 068 8.1 - nothing was touched"
    return 1
  fi
  if [[ "$act" == install && "${SPL_DESK_CRON_CREATE:-0}" == 1 ]]; then
    do_log "INFO DRY_RUN would: git worktree add --detach $SPL_DESK_CRON_SRC origin/${DESK_CRON_TRUNK:-master}"
  fi
  do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
  return 0
}

# Write the lines. Refuses when the crontab after fails spec 068 8.1.
spl_wd_cron_install() {
  local tmp current trunk="${DESK_CRON_TRUNK:-master}" i
  if [[ "${SPL_DESK_CRON_CREATE:-0}" == 1 ]]; then
    git -C "$SPL_DESK_CRON_REPO" fetch -q origin "$trunk" &&
      git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$SPL_DESK_CRON_SRC" "origin/$trunk" ||
      { do_log "FATAL could not create the self-updating checkout $SPL_DESK_CRON_SRC"; return 1; }
  fi
  [[ -x "$SPL_WD_CRON_SCRIPT" ]] || { do_log "FATAL $SPL_WD_CRON_SCRIPT is missing or not executable (is it on trunk yet?)"; return 1; }
  mkdir -p "$SPL_WD_CRON_LOGDIR" 2>/dev/null || { do_log "FATAL cannot create $SPL_WD_CRON_LOGDIR"; return 1; }
  tmp="$(mktemp)" || return 1
  spl_wd_cron_rendered "$tmp"
  if ! spl_wd_cron_gate "$tmp"; then
    rm -f "$tmp"
    do_log "FATAL the crontab after fails spec 068 8.1 - nothing written"
    return 1
  fi
  if ! crontab "$tmp"; then
    rm -f "$tmp"
    do_log "FATAL crontab refused the new file - nothing changed"
    return 1
  fi
  rm -f "$tmp"
  for i in "${!SPL_WD_CRON_TAGS[@]}"; do
    current="$(spl_desk_cron_line "${SPL_WD_CRON_TAGS[$i]}")"
    [[ "$current" == "${SPL_WD_CRON_LINES[$i]}" ]] ||
      { do_log "FATAL the crontab does not read back what was written for ${SPL_WD_CRON_TAGS[$i]}. Got: ${current:-<nothing>}"; return 1; }
  done
  do_log "OK $SPL_WD_CRON_NAME is installed as the box user:"
  for i in "${!SPL_WD_CRON_LINES[@]}"; do
    [[ -n "${SPL_WD_CRON_LINES[$i]}" ]] && spl_desk_cron_say "${SPL_WD_CRON_LINES[$i]}"
  done
  return 0
}

# Take every line of this kind out.
spl_wd_cron_remove() {
  local tmp rc=0
  tmp="$(mktemp)" || return 1
  spl_wd_cron_rendered "$tmp" empty
  crontab "$tmp" || rc=$?
  rm -f "$tmp"
  (( rc == 0 )) || { do_log "FATAL crontab refused the new file (exit $rc)"; return 1; }
  do_log "OK the $SPL_WD_CRON_NAME cron is out of the crontab"
  return 0
}

do_spl_wd_ensure_install_cron() {
  local act="${WD_CRON_ACTION:-install}"
  do_require_bin crontab || return 1
  [[ "${CRON_REMOVE:-0}" == 1 ]] && act=remove
  case "$act" in
    install|remove|check) ;;
    *) do_log "FATAL WD_CRON_ACTION must be install, remove or check, got: '$act'"; return 1 ;;
  esac
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_wd_cron_prep || return 1
  if [[ "$act" == check ]]; then
    spl_wd_cron_check || return 1
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_wd_cron_dry "$act" || return 1
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_wd_cron_remove
    return
  fi
  spl_wd_cron_install
}
