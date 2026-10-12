#!/bin/bash
#------------------------------------------------------------------------------
# @description The fleet's issue key rate on trunk, measured weekly (owner Q6 A,
# @description HUM-10, t1 5ea2e615 msg 910b14c9; spec 135 section 9: the key is
# @description enforced at the lane's exit, the rate measured weekly, and the
# @description pre-push hook considered only if it stays low after two weeks).
# @description Of the non-merge commits on KEY_RATE_REF since KEY_RATE_SINCE:
# @description   cite   the key in the subject scope (any type) or a Closes: trailer
# @description   close  the ones the landed-fix rule closes an issue with
# @description          (scripts/issue-close-landed.py commit_keys, the one parser)
# @description Prints the JSON line of scripts/issue-key-rate.py, then one OK line.
# @description With KEY_RATE_HISTORY it also appends one TSV row there:
# @description   <utc>\t<since>\t<commits>\t<cite>\t<close>\t<cite %>\t<close %>
# @description Read-only on git (the weekly cron fetches first). The rule:
# @description csi-spl-doc/doc/md/lane-issue-and-docs.md section 4.
# @param KEY_RATE_SINCE (optional) - git --since, default "7 days ago"
# @param KEY_RATE_REF (optional) - default origin/master
# @param KEY_RATE_HISTORY (optional) - a TSV file to append the week's row to
# @example ./run -a do_spl_issue_key_rate
# @example KEY_RATE_SINCE='14 days ago' ./run -a do_spl_issue_key_rate
#------------------------------------------------------------------------------
do_spl_issue_key_rate() {
  do_require_bin git python3 jq || return 1
  local since="${KEY_RATE_SINCE:-7 days ago}" ref="${KEY_RATE_REF:-origin/master}" hist="${KEY_RATE_HISTORY:-}" out row
  git -C "$APP_PATH" rev-parse -q --verify "$ref^{commit}" >/dev/null || { do_log "FATAL no such ref in $APP_PATH: $ref"; return 1; }
  out="$(python3 "$PROJ_PATH/src/bash/scripts/issue-key-rate.py" "$APP_PATH" "$ref" "$since")" ||
    { do_log "FATAL cannot read the commits of $ref since $since"; return 1; }
  printf '%s\n' "$out"
  row="$(jq -r '[.commits, .cite, .close, (.cite_pct // "-"), (.close_pct // "-")] | @tsv' <<<"$out")" || return 1
  if [[ -n "$hist" ]]; then
    mkdir -p "$(dirname "$hist")" && printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$since" "$row" >>"$hist" ||
      { do_log "FATAL cannot append to $hist"; return 1; }
  fi
  IFS=$'\t' read -r n c k cp kp <<<"$row"
  do_log "OK key rate on $ref since $since: $n commits, $c cite an issue key ($cp%), $k close one ($kp%)"
}
