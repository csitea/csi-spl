#!/bin/bash
#------------------------------------------------------------------------------
# @description Discard the outdated open issues of a tenant (t1 fda34661): a
# @description fixed rule, no judgement per item. STALE = open (not done /
# @description diss), no update since ISSUE_STALE_BEFORE, and none of the
# @description guards: a sha on ISSUE_GIT_REF newer than the issue's last
# @description update named in its description, a commit there since its last
# @description update that names its key, an assignee that is a live lane, wip
# @description with activity in the last ISSUE_WIP_DAYS, a keep label
# @description (ISSUE_KEEP_LABELS), an open child that is not discarded too
# @description (epics, and any parent). TRIAGE = the keys a triage consensus
# @description tsv gave at least ISSUE_TRIAGE_MIN_VOTES discard votes (the
# @description label and child guards still apply). Comment bodies are not
# @description read: `spool issue` has no read of them, so a sha named only in
# @description a comment does not keep an item.
# @description DRY_RUN=1 (the default) prints the plan, one TSV line per item:
# @description key, status, last update, reason code, reason, title. DRY_RUN=0
# @description comments the reason on each, sets it to diss, never deletes, and
# @description writes an undo file (0600) with one command per item. ISSUE_KEYS_FILE
# @description (an agent check's verdicts) narrows the plan to those keys.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent the hub reads and writes as
# @param ISSUE_STALE_BEFORE (optional) - cutoff date or RFC 3339 UTC time, default 2026-09-30
# @param ISSUE_KEEP_LABELS (optional) - comma list, default needs-owner,keep
# @param ISSUE_WIP_DAYS (optional) - default 7
# @param ISSUE_LIVE_LANES (optional) - comma list of live lane ids; default the fleet lane map's live rows
# @param ISSUE_GIT_REF (optional) - default origin/master, in ISSUE_GIT_DIR (default this repo)
# @param ISSUE_TRIAGE_TSV (optional) - a triage consensus.tsv (key, kind, old_status, outcome, discard_votes, ...)
# @param ISSUE_TRIAGE_MIN_VOTES (optional) - default 4
# @param ISSUE_LIMIT (optional) - list page size 1..500, default 50 (one 100-row open page closed the prd socket)
# @param ISSUE_KEYS_FILE (optional) - keys, one a line (an agent check's verdicts): only those that the rule also selects are planned and discarded
# @param ISSUE_PLAN (optional) - plan path; default $SPL_STATE_DIR/issue-discard/<tenant>-<utc>.plan.tsv
# @param ISSUE_UNDO (optional) - undo path; default the plan path, .undo.sh
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 DRY_RUN=1 ./run -a do_spl_issue_discard_stale
#------------------------------------------------------------------------------
do_spl_issue_discard_stale() {
  local dry=1 work plan rc=0
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_issue_discard_check || return 1
  plan="$(spl_issue_discard_plan_path)" || return 1
  work="$(mktemp -d)"
  if spl_issue_discard_inputs "$work" && spl_issue_discard_select "$work" >"$work/all.tsv" &&
    spl_issue_discard_only_keys <"$work/all.tsv" >"$plan"; then
    spl_issue_discard_finish "$plan" "$dry" || rc=1
  else
    rc=1
  fi
  rm -rf "$work"
  return $rc
}

# spl_issue_discard_check: the shape of every knob, before any hub call.
spl_issue_discard_check() {
  local cut="${ISSUE_STALE_BEFORE:-2026-09-30}"
  [[ "$cut" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:.]+Z)?$ ]] ||
    { do_log "FATAL ISSUE_STALE_BEFORE must be a date like 2026-09-30 or an RFC 3339 UTC time, got: '$cut'"; return 1; }
  [[ "${ISSUE_WIP_DAYS:-7}" =~ ^[0-9]+$ ]] || { do_log "FATAL ISSUE_WIP_DAYS must be a whole number, got: '${ISSUE_WIP_DAYS:-}'"; return 1; }
  [[ "${ISSUE_TRIAGE_MIN_VOTES:-4}" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL ISSUE_TRIAGE_MIN_VOTES must be 1 or more, got: '${ISSUE_TRIAGE_MIN_VOTES:-}'"; return 1; }
  [[ -z "${ISSUE_KEYS_FILE:-}" || -r "$ISSUE_KEYS_FILE" ]] ||
    { do_log "FATAL ISSUE_KEYS_FILE is not a readable file: '$ISSUE_KEYS_FILE'"; return 1; }
  [[ -z "${ISSUE_TRIAGE_TSV:-}" || -r "$ISSUE_TRIAGE_TSV" ]] ||
    { do_log "FATAL ISSUE_TRIAGE_TSV is not a readable file: '$ISSUE_TRIAGE_TSV'"; return 1; }
  spl_issue_limit_or 50 >/dev/null
}

# spl_issue_limit_or DEFAULT -> ISSUE_LIMIT checked, or DEFAULT when unset.
spl_issue_limit_or() {
  local ISSUE_LIMIT="${ISSUE_LIMIT:-$1}"
  spl_issue_limit
}

# spl_issue_discard_plan_path -> ISSUE_PLAN, or a fresh name in a 0700 state dir.
# The plan holds titles (workspace data): it stays 0600, never in git.
spl_issue_discard_plan_path() {
  local p="${ISSUE_PLAN:-${SPL_STATE_DIR}/issue-discard/${TENANT_ID:-tenant}-$(date -u +%Y%m%dT%H%M%SZ).plan.tsv}"
  mkdir -p "$(dirname "$p")" || return 1
  [[ -n "${ISSUE_PLAN:-}" ]] || chmod 700 "$(dirname "$p")"
  (umask 077; : >"$p") || return 1
  printf '%s\n' "$p"
}

# spl_issue_discard_inputs WORK: open.json (every open issue), lanes.txt,
# commits.txt (sha, commit time, keys named) and triage.tsv in WORK.
spl_issue_discard_inputs() {
  local work="$1"
  spl_issue_discard_fetch_open "$work/open.json" || return 1
  spl_issue_discard_lanes >"$work/lanes.txt" || return 1
  spl_issue_discard_commits "$work/commits.txt" || return 1
  if [[ -n "${ISSUE_TRIAGE_TSV:-}" ]]; then cp "$ISSUE_TRIAGE_TSV" "$work/triage.tsv"; else : >"$work/triage.tsv"; fi
}

# spl_issue_discard_fetch_open FILE: every open issue, one status at a time, so
# each page stays a small frame. One merged list document.
spl_issue_discard_fetch_open() {
  local out="$1" lim s page rc
  local -a pages=()
  lim="$(spl_issue_limit_or 50)" || return 1
  for s in eval todo wip blocked onhold qas; do
    page="$(mktemp)"
    pages+=("$page")
    spl_issue_list_fetch --status "$s" --limit "$lim" >"$page" || { rm -f "${pages[@]}"; return 1; }
  done
  spl_issue_merge_pages "${pages[@]}" >"$out"
  rc=$?
  rm -f "${pages[@]}"
  return $rc
}

# spl_issue_discard_lanes -> the live lane ids, one a line, the @box cut off.
spl_issue_discard_lanes() {
  if [[ -n "${ISSUE_LIVE_LANES+x}" ]]; then
    tr ',' '\n' <<<"$ISSUE_LIVE_LANES" | sed 's/@.*//; /^$/d'
    return 0
  fi
  local lm="$PROJ_PATH/src/bash/features/spawn-agents/scripts/lane-map.sh" raw
  raw="$(bash "$lm" list --json 2>/dev/null)" || { do_log "FATAL the fleet lane map did not answer: set ISSUE_LIVE_LANES"; return 1; }
  python3 -c 'import json,sys
for r in json.loads(sys.stdin.read()).get("lanes") or []:
    if r.get("state") == "live" and r.get("agent_id"):
        print(r["agent_id"])' <<<"$raw"
}

# spl_issue_discard_commits FILE: "<sha> <unix time> <KEY>..." per commit on
# ISSUE_GIT_REF, with the issue keys its message names.
spl_issue_discard_commits() {
  local out="$1" dir="${ISSUE_GIT_DIR:-$PROJ_PATH}" ref="${ISSUE_GIT_REF:-origin/master}"
  git -C "$dir" rev-parse --verify -q "$ref^{commit}" >/dev/null ||
    { do_log "FATAL $ref is not a commit in $dir: fetch first or set ISSUE_GIT_REF"; return 1; }
  git -C "$dir" log "$ref" --format='%x1e%H %ct%n%B' | python3 -c 'import re,sys
for rec in sys.stdin.read().split("\x1e"):
    if not rec.strip():
        continue
    head, _, body = rec.partition("\n")
    keys = sorted(set(re.findall(r"\b[A-Z][A-Z0-9]{0,9}-[1-9][0-9]*\b", body)))
    print(" ".join([head] + keys))' >"$out"
}

# spl_issue_discard_only_keys: the plan lines on stdin, cut to the keys of
# ISSUE_KEYS_FILE when it is set (first word of each line). A key the rule did
# not select stays kept: the file narrows the rule, never widens it.
spl_issue_discard_only_keys() {
  [[ -n "${ISSUE_KEYS_FILE:-}" ]] || { cat; return 0; }
  awk -F'\t' 'NR == FNR { if ($1 != "") ok[$1] = 1; next } ($1 in ok)' \
    <(awk '{ print $1 }' "$ISSUE_KEYS_FILE") -
}

# spl_issue_discard_select WORK -> the plan TSV (key, status, updated, code,
# reason, title); the kept counts per guard go to stderr.
spl_issue_discard_select() {
  python3 "$PROJ_PATH/src/bash/scripts/issue-discard-select.py" "$1" "${ISSUE_STALE_BEFORE:-2026-09-30}" \
    "${ISSUE_KEEP_LABELS-needs-owner,keep}" "${ISSUE_WIP_DAYS:-7}" "${ISSUE_TRIAGE_MIN_VOTES:-4}" "${ISSUE_NOW:-}"
}

# spl_issue_discard_finish PLAN DRY: the counts; the plan, or the discard.
spl_issue_discard_finish() {
  local plan="$1" dry="$2" n
  n="$(grep -c . "$plan" || true)"
  do_log "INFO $n items by status/reason: $(spl_issue_discard_counts "$plan")"
  if (( dry )); then
    cat "$plan"
    do_log "OK DRY_RUN count=$n nothing was discarded. PLAN $plan"
    return 0
  fi
  spl_issue_discard_apply "$plan"
}

# spl_issue_discard_counts PLAN -> "status/code=n ..." on one line.
spl_issue_discard_counts() {
  awk -F'\t' 'NF { c[$2 "/" $4]++ } END { for (k in c) print k "=" c[k] }' "$1" | sort | tr '\n' ' '
}

# spl_issue_discard_apply PLAN: comment, then diss, one item at a time; the
# undo file grows a line as each item changes.
spl_issue_discard_apply() {
  local plan="$1" undo="${ISSUE_UNDO:-${1%.tsv}.undo.sh}" key status code why n=0 fail=0
  (umask 077; printf '#!/bin/bash\n# undo do_spl_issue_discard_stale (%s): each item back to its old status\n' "$plan" >"$undo") || return 1
  spl_desk_issue_once || return 1
  while IFS=$'\t' read -r key status _ code why _; do
    [[ -n "$key" ]] || continue
    if spl_issue_discard_one "$key" "$code" "$why"; then
      printf 'cd %q && ENV=%q TENANT_ID=%q DESK_AGENT=%q ISSUE_REF=%q ISSUE_STATUS=%q DRY_RUN=0 ./run -a do_spl_issue_update\n' \
        "$PROJ_PATH" "$ENV" "$TENANT_ID" "$DESK_AGENT" "$key" "$status" >>"$undo"
      n=$((n + 1))
    else
      fail=$((fail + 1))
    fi
  done <"$plan"
  do_log "UNDO $undo"
  (( fail == 0 )) || { do_log "FATAL discarded $n, $fail failed (above)"; return 1; }
  do_log "OK discarded $n items"
}

# spl_issue_discard_one KEY CODE WHY: the reason comment, then status diss.
spl_issue_discard_one() {
  local key="$1" code="$2" why="$3" out
  out="$(spl_desk_issue_run comment --ref "$key" \
    --body "Discarded as outdated by do_spl_issue_discard_stale ($code): $why. Nothing was deleted; setting the old status back undoes it." 2>&1)" ||
    { do_log "FATAL comment $key: $out"; return 1; }
  out="$(spl_desk_issue_run update --ref "$key" --status diss 2>&1)" ||
    { do_log "FATAL diss $key: $out"; return 1; }
}
