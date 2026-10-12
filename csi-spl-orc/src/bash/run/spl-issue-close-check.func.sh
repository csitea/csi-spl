#!/bin/bash
#------------------------------------------------------------------------------
# @description The lane exit check of the landed-fix rule (t1 dee4081d, brief
# @description item 3): for each commit a lane landed, the issues it closes by
# @description the rule of do_spl_issue_close_landed (scripts/issue-close-landed.py
# @description --keys), and each one's status on the hub. One TSV row per key:
# @description   <key> closed-by-rule <sha>   done, and the rule's ledger holds it
# @description   <key> done | diss            closed by hand (or by the qas rule)
# @description   <key> qas review-asked      in a review a human asked for (spec 135 Q7):
# @description                               the reviewer closes it, the lane may exit
# @description   <key> OPEN <status>          still open (or reopened): the lane may not exit
# @description   <key> unknown <why>          the hub read failed
# @description Exit 0 when every key is closed (or none is named), 3 when one
# @description is OPEN, 1 when a read failed. Read-only: it calls the hub's
# @description issue get, so like every desk read it needs DRY_RUN=0.
# @param ENV - required: dev or prd, the hub of the issues
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent that reads (a desk seated on this box)
# @param DESK_BOX (optional) - default the box's desk (spl_desk_box_default)
# @param ISSUE_CLOSE_SHAS - required: the lane's landed commits, space or comma separated
# @param ISSUE_CLOSE_STATE_DIR (optional) - as do_spl_issue_close_landed (the ledger)
# @param DRY_RUN (optional) - must be 0 for the hub read; 1 prints the keys only
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-685 DESK_BOX=box-ci ISSUE_CLOSE_SHAS=47f124353 DRY_RUN=0 ./run -a do_spl_issue_close_check
#------------------------------------------------------------------------------
do_spl_issue_close_check() {
  do_require_bin git python3 jq || return 1
  local shas="${ISSUE_CLOSE_SHAS:-}" dir key out st rc=0 open=0
  local -a keys=() sha_list=()
  read -r -a sha_list <<<"${shas//,/ }"
  (( ${#sha_list[@]} )) || { do_log "FATAL ISSUE_CLOSE_SHAS must name the lane's commits"; return 1; }
  mapfile -t keys < <(python3 "$PROJ_PATH/src/bash/scripts/issue-close-landed.py" --keys "$APP_PATH" "${sha_list[@]}") ||
    { do_log "FATAL cannot read those commits: $shas"; return 1; }
  if (( ${#keys[@]} == 0 )); then do_log "OK the lane's commits name no issue by the rule"; return 0; fi
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    printf '%s\tnamed\n' "${keys[@]}"
    do_log "OK DRY_RUN ${#keys[@]} key(s) named; DRY_RUN=0 reads their status"
    return 0
  fi
  dir="$(spl_icl_state_dir)" || return 1
  for key in "${keys[@]}"; do
    if ! out="$(spl_desk_issue_run get --ref "$key" 2>&1)"; then
      printf '%s\tunknown\t%s\n' "$key" "$(tail -n 1 <<<"$out" | cut -c1-160)"; rc=1; continue
    fi
    st="$(jq -r '.result.issue.status // ""' <<<"$out" 2>/dev/null | tail -n 1)"
    case "$st" in
      done|diss)
        local by
        by="$(awk -F'\t' -v k="$key" '$1 == k && $3 != "noop" { s = $2 } END { print s }' "$dir/closed.tsv" 2>/dev/null)"
        if [[ -n "$by" && "$st" == "done" ]]; then printf '%s\tclosed-by-rule\t%s\n' "$key" "$by"; else printf '%s\t%s\n' "$key" "$st"; fi ;;
      qas) printf '%s\tqas\treview-asked\n' "$key" ;;
      "") printf '%s\tunknown\tno status in the hub answer\n' "$key"; rc=1 ;;
      *)
        local was
        was="$(awk -F'\t' -v k="$key" '$1 == k && $3 != "noop" { s = $2 } END { print s }' "$dir/closed.tsv" 2>/dev/null)"
        printf '%s\tOPEN\t%s%s\n' "$key" "$st" "${was:+ (reopened after the rule closed it by ${was:0:12})}"
        open=$((open + 1)) ;;
    esac
  done
  if (( open )); then
    do_log "FAIL $open issue(s) the lane's commits name are still open: the hourly do_spl_issue_close_landed closes them, or move them by hand (do_spl_issue_update)"
    return 3
  fi
  return $rc
}
