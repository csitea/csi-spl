#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove, or check) the watchdog keeper cron (spec 093
# @description section 6): ONE line in the box user's crontab running
# @description do_spl_wd_ensure at `* * * * *`. Tagged `# <org>-<app>:wd-ensure`,
# @description matched EXACTLY at the end of the line; idempotent (the tagged
# @description line is replaced in place, never appended). It points at the
# @description same self-updating checkout as the desk reconcile
# @description (<shared checkout>-desk-cron, DESK_CRON_SRC overrides; an agent
# @description worktree is refused). No fetch on the line: a fetch every minute
# @description buys nothing the desk reconcile's five-minute one does not.
# @description Spec 068 section 8.1 is applied to THIS line only. Other crontab
# @description lines belong to other jobs and do not block the install. A
# @description wd-ensure line whose script is outside a checkout is still refused.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param WD_CRON_ACTION (optional) - install (default) | remove | check
# @param CRON_REMOVE (optional) - 1 = WD_CRON_ACTION=remove
# @param WD_ENSURE_WATCH_DRY (optional) - 0 or 1, copied onto the cron line.
# @param   Unset: the line sets nothing and the keeper acts. 1: the watchdog
# @param   only observes (no ring, no takeover) for that run.
# @param WD_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/wd
# @param DESK_CRON_SRC / DESK_CRON_SELF_UPDATE / DESK_CRON_TRUNK (optional) - as do_spl_desk_install_service
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_wd_ensure_install_cron
# @example DRY_RUN=0 ./run -a do_spl_wd_ensure_install_cron
# @example WD_ENSURE_WATCH_DRY=1 DRY_RUN=0 ./run -a do_spl_wd_ensure_install_cron
# @example WD_CRON_ACTION=check ./run -a do_spl_wd_ensure_install_cron
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

# SPL_WD_CRON_TAG / _LINE / _SCRIPT / _LOGDIR. No per-minute git fetch.
spl_wd_cron_prep() {
  local trunk="${DESK_CRON_TRUNK:-master}"
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "${PROJ_PATH:-csi-spl-orc}")}"
  SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  [[ "$trunk" =~ ^[A-Za-z0-9._/-]+$ ]] || { do_log "FATAL DESK_CRON_TRUNK is not a branch name: '$trunk'"; return 1; }
  spl_desk_cron_src || return 1
  SPL_WD_CRON_TAG="$SPL_ORG_APP:wd-ensure"
  SPL_WD_CRON_SCRIPT="$SPL_DESK_CRON_SRC/$SPL_ORG_APP-orc/run"
  SPL_WD_CRON_LOGDIR="${WD_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/wd}"
  local watch=""
  if [[ -n "${WD_ENSURE_WATCH_DRY:-}" ]]; then
    [[ "$WD_ENSURE_WATCH_DRY" == 0 || "$WD_ENSURE_WATCH_DRY" == 1 ]] ||
      { do_log "FATAL WD_ENSURE_WATCH_DRY must be 0 or 1, got: '$WD_ENSURE_WATCH_DRY'"; return 1; }
    watch="WD_ENSURE_WATCH_DRY=$WD_ENSURE_WATCH_DRY "
  fi
  SPL_WD_CRON_LINE="* * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ${watch}$SPL_WD_CRON_SCRIPT -a do_spl_wd_ensure >> $SPL_WD_CRON_LOGDIR/ensure.out 2>&1 # $SPL_WD_CRON_TAG"
  return 0
}

# spl_wd_cron_rendered OUT LINE: the crontab with the tagged line set to LINE
# (empty LINE removes it). A missing crontab reads as empty.
spl_wd_cron_rendered() {
  { crontab -l 2>/dev/null || true; } | spl_desk_cron_render "$SPL_WD_CRON_TAG" "$2" > "$1"
}

# 8.1 on the wd-ensure line only. Other lines are other jobs.
spl_wd_cron_gate() {
  local tmp rc=0 out
  tmp="$(mktemp)" || return 1
  grep -E " # ${SPL_WD_CRON_TAG}$" "$1" > "$tmp" || true
  if [[ -s "$tmp" ]]; then
    out="$(spl_wd_cron_8_1 "$tmp")" || rc=$?
  else
    out="OK 8.1 0 command line(s), 0 failing"
  fi
  rm -f "$tmp"
  echo "---- spec 068 8.1 on the wd-ensure line:"
  printf '%s\n' "$out" | sed 's/^/    /'
  return "$rc"
}

spl_wd_cron_diff() {
  local tmp line="$1"
  tmp="$(mktemp -d)" || return 1
  { crontab -l 2>/dev/null || true; } > "$tmp/before"
  spl_desk_cron_render "$SPL_WD_CRON_TAG" "$line" < "$tmp/before" > "$tmp/after"
  echo "    crontab diff (before -> after):"
  diff -u --label before --label after "$tmp/before" "$tmp/after" | sed 's/^/    /' || true
  if cmp -s "$tmp/before" "$tmp/after"; then echo "    (no change)"; fi
  rm -rf "$tmp"
}

spl_wd_cron_check() {
  local current="$1" ran
  [[ -n "$current" ]] || { do_log "FAIL wd-ensure is NOT installed (no line tagged $SPL_WD_CRON_TAG)"; return 1; }
  spl_desk_cron_say "$current"
  ran="$(spl_wd_cron_script_of "$current")"
  [[ -n "$ran" && -x "$ran" ]] || { do_log "FAIL the line names a script that is gone or not executable: ${ran:-<none>}"; return 1; }
  [[ "$current" == "$SPL_WD_CRON_LINE" ]] || do_log "INFO installed with other settings than this call would write - working"
  do_log "OK wd-ensure is installed and its script is executable"
  return 0
}

# Dry run: the diff and the 8.1 check, nothing written. Non-zero when 8.1 fails.
spl_wd_cron_dry() {
  local act="$1" line="" tmp rc=0
  [[ "$act" == install ]] && line="$SPL_WD_CRON_LINE"
  tmp="$(mktemp -d)" || return 1
  spl_wd_cron_rendered "$tmp/after" "$line"
  spl_wd_cron_diff "$line"
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

# Write the line. Refuses when the crontab after fails spec 068 8.1.
spl_wd_cron_install() {
  local tmp current trunk="${DESK_CRON_TRUNK:-master}"
  if [[ "${SPL_DESK_CRON_CREATE:-0}" == 1 ]]; then
    git -C "$SPL_DESK_CRON_REPO" fetch -q origin "$trunk" &&
      git -C "$SPL_DESK_CRON_REPO" worktree add -q --detach "$SPL_DESK_CRON_SRC" "origin/$trunk" ||
      { do_log "FATAL could not create the self-updating checkout $SPL_DESK_CRON_SRC"; return 1; }
  fi
  [[ -x "$SPL_WD_CRON_SCRIPT" ]] || { do_log "FATAL $SPL_WD_CRON_SCRIPT is missing or not executable (is it on trunk yet?)"; return 1; }
  mkdir -p "$SPL_WD_CRON_LOGDIR" 2>/dev/null || { do_log "FATAL cannot create $SPL_WD_CRON_LOGDIR"; return 1; }
  tmp="$(mktemp)" || return 1
  spl_wd_cron_rendered "$tmp" "$SPL_WD_CRON_LINE"
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
  current="$(spl_desk_cron_line "$SPL_WD_CRON_TAG")"
  [[ "$current" == "$SPL_WD_CRON_LINE" ]] || { do_log "FATAL the crontab does not read back what was written. Got: ${current:-<nothing>}"; return 1; }
  do_log "OK wd-ensure is installed as the box user:"
  spl_desk_cron_say "$SPL_WD_CRON_LINE"
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
    spl_wd_cron_check "$(spl_desk_cron_line "$SPL_WD_CRON_TAG")" || return 1
    return 0
  fi
  if [[ "${DRY_RUN:-1}" == 1 ]]; then
    spl_wd_cron_dry "$act" || return 1
    return 0
  fi
  if [[ "$act" == remove ]]; then
    spl_desk_cron_write "$SPL_WD_CRON_TAG" "" || return 1
    do_log "OK the wd-ensure cron is out of the crontab"
    return 0
  fi
  spl_wd_cron_install
}
