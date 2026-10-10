#!/bin/bash
#------------------------------------------------------------------------------
# @description Drop every crontab line tagged `# <tag>` (matched only as the
# @description whole END of a line, so a line that merely contains the tag
# @description mid-line stays), append <line> when one is given, and report
# @description whether the crontab changed: "OK cron: nothing to change", or
# @description the diff before -> after (PLAN in a dry run, DO otherwise).
# @description Writes the crontab only when <dry> is 0 and it changed, after
# @description creating <log-dir> when a line is appended. The install-cron
# @description actions share it; each keeps its own final message and rc:
# @description   cron_drop_tagged_line ... || return $(( $? == 2 ? 0 : 1 ))
# @param crontab-cmd (required) - the crontab command (a fake one in tests)
# @param tag (required) - the tag, without the leading "# "
# @param dry (required) - 1 plans only, 0 writes
# @param log-dir (required) - created before a line is appended for real
# @param line (optional) - the line to append; empty or absent only drops
# @return 0 the crontab was written; 2 nothing was written (unchanged, or a
# @return dry run; already reported); 1 FATAL (logged)
# @example cron_drop_tagged_line crontab csi-spl:docker-prune 0 /var/log/x "$want"
#------------------------------------------------------------------------------
cron_drop_tagged_line() {
  local ct="$1" tag="$2" dry="$3" logdir="$4" line="${5:-}" before after
  before="$(mktemp)"; after="$(mktemp)"
  $ct -l 2>/dev/null >"$before" || true
  awk -v suf=" # $tag" '{ l = length($0); s = length(suf); if (l >= s && substr($0, l - s + 1) == suf) next; print }' "$before" >"$after"
  [[ -n "$line" ]] && printf '%s\n' "$line" >>"$after"
  if cmp -s "$before" "$after"; then
    echo "OK cron: nothing to change"; rm -f "$before" "$after"; return 2
  fi
  echo "$([[ "$dry" == 1 ]] && echo PLAN || echo DO) cron: the crontab before -> after"
  diff -u --label before --label after "$before" "$after" | sed 's/^/  /' || true
  if [[ "$dry" == 1 ]]; then
    rm -f "$before" "$after"; do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 2
  fi
  if [[ -n "$line" ]] && ! mkdir -p "$logdir"; then
    rm -f "$before" "$after"; do_log "FATAL cannot create $logdir (the log dir)"; return 1
  fi
  $ct "$after" || { rm -f "$before" "$after"; do_log "FATAL crontab refused the new file"; return 1; }
  rm -f "$before" "$after"
}
