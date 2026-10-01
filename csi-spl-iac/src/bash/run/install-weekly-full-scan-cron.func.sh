#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Install (or remove) the box cron line of the weekly full scan:
# @description Friday 17:00 BOX LOCAL time (cron follows the box timezone, so
# @description EEST/EET), running weekly-full-scan-cron.sh from the
# @description self-updating <shared checkout>-desk-cron checkout (each run first
# @description moves it to origin/<trunk>), log in WEEKLY_SCAN_LOG_DIR.
# @description ONE line, tagged `# <app>:weekly-full-scan` and matched EXACTLY at
# @description the end of the line, so no other line is touched (a prefix match
# @description deleted the -prd desk line on 2026-10-01). Idempotent.
# @description DRY_RUN=1 (the default) prints the crontab diff and changes nothing.
# @param WEEKLY_SCAN_CRON_ACTION (optional) - install (default) | remove
# @param WEEKLY_SCAN_CRON_SRC (optional) - the checkout the line runs from, default
# @param        <shared checkout>-desk-cron (the desk reconcile's self-updating one)
# @param WEEKLY_SCAN_CRON_TRUNK (optional) - default master
# @param WEEKLY_SCAN_LOG_DIR (optional) - default /var/<org>/<app>/weekly-scan
# @param WEEKLY_SCAN_CRONTAB (optional, tests) - a crontab FILE to edit instead of `crontab`
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_install_weekly_full_scan_cron
# @example DRY_RUN=0 ./run -a do_install_weekly_full_scan_cron
# @example WEEKLY_SCAN_CRON_ACTION=remove DRY_RUN=0 ./run -a do_install_weekly_full_scan_cron
#------------------------------------------------------------------------------

_iwfs_read() {
  if [[ -n "${WEEKLY_SCAN_CRONTAB:-}" ]]; then cat "$WEEKLY_SCAN_CRONTAB" 2>/dev/null || true
  else crontab -l 2>/dev/null || true; fi
}
_iwfs_write() {  # <file>
  if [[ -n "${WEEKLY_SCAN_CRONTAB:-}" ]]; then cp "$1" "$WEEKLY_SCAN_CRONTAB"
  else crontab "$1"; fi
}

do_install_weekly_full_scan_cron() {
  local act="${WEEKLY_SCAN_CRON_ACTION:-install}" trunk="${WEEKLY_SCAN_CRON_TRUNK:-master}"
  case "$act" in install|remove) ;; *) do_log "FATAL WEEKLY_SCAN_CRON_ACTION must be install or remove, got '$act'"; return 1 ;; esac
  [[ -n "${WEEKLY_SCAN_CRONTAB:-}" ]] || command -v crontab >/dev/null 2>&1 || { do_log "FATAL crontab not found"; return 1; }

  local common repo app org src logdir tag line
  common="$(git -C "$APP_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { do_log "FATAL $APP_PATH is not in a git checkout"; return 1; }
  repo="$(dirname "$common")"; app="$(basename "$repo")"; org="${app%%-*}"
  src="${WEEKLY_SCAN_CRON_SRC:-$repo-desk-cron}"
  case "$src" in */*-wt/*) do_log "FATAL $src is an agent worktree: it is deleted when its agent finishes, and the job would stop silently"; return 1 ;; esac
  logdir="${WEEKLY_SCAN_LOG_DIR:-/var/$org/$app/weekly-scan}"
  tag="# $app:weekly-full-scan"
  line="0 17 * * 5 cd $src && git fetch -q origin $trunk && git checkout -q --detach origin/$trunk; DRY_RUN=0 $src/csi-spl-iac/src/bash/scripts/weekly-full-scan-cron.sh >> $logdir/cron.out 2>&1 $tag"

  local old new
  old="$(mktemp)"; new="$(mktemp)"
  _iwfs_read >"$old"
  # keep every line whose END is not exactly the tag
  awk -v t="$tag" '{ n=length($0); m=length(t); if (n >= m && substr($0, n-m+1) == t) next; print }' "$old" >"$new"
  [[ "$act" == install ]] && printf '%s\n' "$line" >>"$new"

  if cmp -s "$old" "$new"; then
    do_log "INFO weekly full scan cron: nothing to change ($act)"; rm -f "$old" "$new"; return 0
  fi
  diff -u --label crontab.now --label crontab.after "$old" "$new"
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "OK DRY_RUN the crontab is unchanged. Re-run with DRY_RUN=0 to $act."
    rm -f "$old" "$new"; return 0
  fi
  if [[ "$act" == install ]]; then
    [[ -x "$src/csi-spl-iac/src/bash/scripts/weekly-full-scan-cron.sh" || -n "${WEEKLY_SCAN_CRONTAB:-}" ]] \
      || do_log "WARN $src does not carry weekly-full-scan-cron.sh yet -- its first run moves it to origin/$trunk"
    mkdir -p "$logdir" 2>/dev/null || { sudo mkdir -p "$logdir" && sudo chown "$(id -un)" "$logdir"; } 2>/dev/null || true
  fi
  _iwfs_write "$new" || { do_log "FATAL could not write the crontab"; rm -f "$old" "$new"; return 1; }
  rm -f "$old" "$new"
  do_log "INFO weekly full scan cron: ${act}ed ($tag)"
}
