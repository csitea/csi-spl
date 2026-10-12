#!/bin/bash
#------------------------------------------------------------------------------
# @description A fix landed on master closes the issues it names (owner HUM-10,
# @description t1 dee4081d msg ea519baa: "Done should be the automatic target").
# @description The rule, as code (scripts/issue-close-landed.py holds the parse):
# @description   - a fix / feat / perf / refactor commit whose subject scope
# @description     carries the key, "fix(orc, SPL-12): ...", or any commit with
# @description     a "Closes: SPL-12" trailer; a bare mention in the body or a
# @description     "Refs: SPL-12" trailer never closes
# @description   - each OPEN issue so named gets a comment with the sha(s) and
# @description     the release note link, then moves to done; an issue already
# @description     done or diss is a no-op; an epic or a feature is skipped
# @description   - every (issue, sha) pair acted on goes to a ledger (closed.tsv:
# @description     key, sha, moved | noop) and never
# @description     acts again: an issue the owner reopens is not closed again by
# @description     the same sha (a newer commit naming it may close it)
# @description Reads the commits after the cursor (the master sha of the last
# @description complete run) up to ISSUE_CLOSE_REF; the first run needs
# @description ISSUE_CLOSE_SINCE=all (the back-fill: master's whole history) or
# @description a sha. Standing: the box cron issue-close-landed (hourly, the
# @description box that seats the CI ops desk), not a CI job: a move needs the
# @description desk's box-signed hub session, which no CI runner holds.
# @description Prints one TSV row per named key (key, moved | would-move |
# @description noop | skip | failed, sha(s), detail) and a summary line. Reads
# @description the issue list and git even with DRY_RUN=1; writes the hub, the
# @description ledger and the cursor only with DRY_RUN=0.
# @param ENV - required: dev or prd, the hub of the issues
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent that comments and moves
# @param DESK_BOX (optional) - default the box's desk (spl_desk_box_default)
# @param ISSUE_CLOSE_REF (optional) - the trunk ref read, default origin/master
# @param ISSUE_CLOSE_FETCH (optional) - 1 (default) fetches the ref's remote first
# @param ISSUE_CLOSE_SINCE (optional) - all | <sha>: read from there instead of the cursor
# @param ISSUE_CLOSE_STATE_DIR (optional) - the cursor + ledger dir, default
# @param   ${XDG_STATE_HOME:-$HOME/.local/state}/<org>-<app>/issue-close-landed/<env>-<tenant>
# @param ISSUE_CLOSE_EVIDENCE (optional) - TSV key, sha[,sha], why: landings a review cited
# @param   though no commit names the key by the rule (a triage back-fill); same comment + ledger
# @param ISSUE_CLOSE_WUI_URL (optional) - the release note host, default the cnf's WUI
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-685 DESK_BOX=box-ci ISSUE_CLOSE_SINCE=all ./run -a do_spl_issue_close_landed
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-685 DESK_BOX=box-ci DRY_RUN=0 ./run -a do_spl_issue_close_landed
#------------------------------------------------------------------------------
do_spl_issue_close_landed() {
  do_require_bin git python3 || return 1
  local dry=1 ref="${ISSUE_CLOSE_REF:-origin/master}" since="${ISSUE_CLOSE_SINCE:-}" dir head rng wui list plan
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  dir="$(spl_icl_state_dir)" || return 1
  if [[ "${ISSUE_CLOSE_FETCH:-1}" == 1 && "$ref" == */* ]]; then
    git -C "$APP_PATH" fetch -q "${ref%%/*}" "${ref#*/}" || { do_log "FATAL git fetch $ref failed"; return 1; }
  fi
  head="$(git -C "$APP_PATH" rev-parse -q --verify "$ref^{commit}")" || { do_log "FATAL $ref is not a commit"; return 1; }
  rng="$(spl_icl_range "$dir" "$since" "$head")" || return 1
  wui="$(spl_icl_wui_url)" || return 1
  list="$(mktemp)"; plan="$(mktemp)"
  spl_issue_list_fetch --status eval,todo,wip,blocked,onhold,qas --limit 500 >"$list" ||
    { rm -f "$list" "$plan"; return 1; }
  local -a ev=()
  if [[ -n "${ISSUE_CLOSE_EVIDENCE:-}" ]]; then
    [[ -r "$ISSUE_CLOSE_EVIDENCE" ]] || { do_log "FATAL ISSUE_CLOSE_EVIDENCE is not a readable file: '$ISSUE_CLOSE_EVIDENCE'"; rm -f "$list" "$plan"; return 1; }
    ev=("$ISSUE_CLOSE_EVIDENCE")
  fi
  python3 "$PROJ_PATH/src/bash/scripts/issue-close-landed.py" "$list" "$APP_PATH" "$rng" "$dir/closed.tsv" "${ev[@]}" >"$plan" ||
    { do_log "FATAL issue-close-landed.py failed"; rm -f "$list" "$plan"; return 1; }
  rm -f "$list"
  local rc=0
  spl_icl_apply "$plan" "$dry" "$dir" "$wui" || rc=$?
  rm -f "$plan"
  if (( rc == 0 && ! dry )); then
    printf '%s\n' "$head" >"$dir/cursor.tmp" && mv "$dir/cursor.tmp" "$dir/cursor"
    do_log "OK cursor at ${head:0:12} ($dir/cursor)"
  elif (( rc != 0 )); then
    do_log "WARN the cursor stays: the next run retries the range (the ledger keeps the moves that landed)"
  fi
  return $rc
}

# spl_icl_state_dir -> the cursor + ledger dir of ENV + TENANT_ID, created.
spl_icl_state_dir() {
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { do_log "FATAL TENANT_ID is not a tenant id: '${TENANT_ID:-}'" >&2; return 1; }
  local oa
  oa="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"; oa="${oa%-orc}"
  local d="${ISSUE_CLOSE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$oa/issue-close-landed/${ENV:?ENV unset}-$TENANT_ID}"
  mkdir -p "$d" || { do_log "FATAL cannot create $d" >&2; return 1; }
  printf '%s\n' "$d"
}

# spl_icl_range DIR SINCE HEAD -> the git range: SINCE=all the whole history,
# a sha <sha>..HEAD, empty the saved cursor (none saved = refuse: run the
# back-fill first, so a first cron tick never reads 5000 commits unasked).
spl_icl_range() {
  local dir="$1" since="$2" head="$3" c
  if [[ "$since" == all ]]; then printf '%s\n' "$head"; return 0; fi
  if [[ -z "$since" ]]; then
    [[ -s "$dir/cursor" ]] || { do_log "FATAL no cursor in $dir: run the back-fill once (ISSUE_CLOSE_SINCE=all, DRY_RUN=1 then 0)" >&2; return 1; }
    since="$(head -n 1 "$dir/cursor")"
  fi
  c="$(git -C "$APP_PATH" rev-parse -q --verify "$since^{commit}")" || { do_log "FATAL '$since' is not a commit in $APP_PATH" >&2; return 1; }
  git -C "$APP_PATH" merge-base --is-ancestor "$c" "$head" ||
    { do_log "FATAL ${c:0:12} is not an ancestor of ${head:0:12}: master was rewritten? set ISSUE_CLOSE_SINCE" >&2; return 1; }
  printf '%s..%s\n' "$c" "$head"
}

# spl_icl_wui_url -> the WUI base of ENV (the release note host), from the cnf.
spl_icl_wui_url() {
  if [[ -n "${ISSUE_CLOSE_WUI_URL:-}" ]]; then printf '%s\n' "${ISSUE_CLOSE_WUI_URL%/}"; return 0; fi
  do_spl_desk_cnf >&2 || return 1
  [[ -n "${SPL_WUI_URL:-}" ]] || { do_log "FATAL the cnf gives no WUI host for $ENV" >&2; return 1; }
  printf '%s\n' "$SPL_WUI_URL"
}

# spl_icl_apply PLAN DRY DIR WUI: act on each row, print the report. A failed
# move is reported, the others still run, and the return is 1.
spl_icl_apply() {
  local plan="$1" dry="$2" dir="$3" wui="$4" key verdict shas detail moved=0 noop=0 skip=0 failed=0 s
  while IFS=$'\t' read -r key verdict shas detail; do
    [[ -n "$key" ]] || continue
    case "$verdict" in
      close)
        if (( dry )); then
          printf '%s\twould-move\t%s\t%s\n' "$key" "$shas" "$detail"; moved=$((moved + 1))
        elif spl_icl_move "$key" "$shas" "$detail" "$wui"; then
          for s in ${shas//,/ }; do printf '%s\t%s\tmoved\n' "$key" "$s" >>"$dir/closed.tsv"; done
          printf '%s\tmoved\t%s\t%s\n' "$key" "$shas" "$detail"; moved=$((moved + 1))
        else
          printf '%s\tfailed\t%s\tthe comment or the move failed (see the log)\n' "$key" "$shas"; failed=$((failed + 1))
        fi ;;
      noop)
        (( dry )) || for s in ${shas//,/ }; do printf '%s\t%s\tnoop\n' "$key" "$s" >>"$dir/closed.tsv"; done
        printf '%s\tnoop\t%s\t%s\n' "$key" "$shas" "$detail"; noop=$((noop + 1)) ;;
      *)
        printf '%s\tskip\t%s\t%s\n' "$key" "$shas" "$detail"; skip=$((skip + 1)) ;;
    esac
  done <"$plan"
  do_log "OK issue close landed: $moved $( ((dry)) && echo would-move || echo moved), $noop no-op, $skip skipped, $failed failed"
  (( failed == 0 ))
}

# spl_icl_move KEY SHAS SUBJECT WUI: the audit comment, then status done.
spl_icl_move() {
  local key="$1" shas="$2" subject="$3" wui="$4" body s lines=""
  for s in ${shas//,/ }; do lines+="- ${s:0:12}: $wui/releases/$s"$'\n'; done
  body="Landed on master, so done (owner rule, t1 dee4081d msg ea519baa), by do_spl_issue_close_landed.

${lines}
The newest: $subject

Reopen it if it is not done: the same commit never closes it again."
  spl_desk_issue_run comment --ref "$key" --body "$body" >/dev/null || return 1
  spl_desk_issue_run update --ref "$key" --status "done" >/dev/null || return 1
}
