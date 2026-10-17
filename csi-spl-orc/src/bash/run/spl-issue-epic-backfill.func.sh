#!/bin/bash
#------------------------------------------------------------------------------
# @description Give every orphan issue of a workspace an epic (SPL-2354; owner
# @description HUM-10, t1 7a98c2d1, msg 52da8fbb: "Go scan all of the issues
# @description and create needed new epics: the whole Jira part of our
# @description application should look consistent"). An orphan is a live
# @description level-2 issue with no epic and no parent; done issues are
# @description linked too, their status untouched. Its epic, in this order:
# @description the epic of the spec folder its description names
# @description (csi-spl-doc/specs/NNN-...), else ONE new 'Spec NNN - <heading>'
# @description epic per spec, else an 'Area: <name> - issues with no spec'
# @description epic (title scope, unanswered blocker, owner answer, the repo
# @description dir it names most, other). A spec is never guessed. The rules
# @description and the held case: src/bash/scripts/issue-epic-backfill.py.
# @description DRY_RUN=1 (the default) prints the plan and writes nothing: the
# @description summary table, the no-spec issues by area, the held ones.
# @description DRY_RUN=0 creates each needed epic (do_spl_issue_create), then
# @description links its issues (do_spl_issue_update ISSUE_EPIC), one row per
# @description write, at most ISSUE_BACKFILL_LIMIT links a run: re-run it for
# @description the next batch; a run on its own output plans 0 writes. It
# @description writes an undo file (0600). ISSUE_BACKFILL_CMD=verify lists
# @description the workspace and fails when an orphan is left or two live
# @description epics share a title. Archived issues are hidden from every hub
# @description read, so neither mode sees or links them.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the workspace the desk is seated in
# @param DESK_AGENT - required: the agent the hub reads and writes as
# @param ISSUE_BACKFILL_CMD (optional) - plan (default) or verify
# @param ISSUE_BACKFILL_LIMIT (optional) - links per DRY_RUN=0 run, default 100, 0 = all
# @param ISSUE_BACKFILL_SKIP (optional) - comma list of workspaces left alone, default e2e (the test workspace)
# @param ISSUE_PLAN_DIR (optional) - plan dir; default $SPL_STATE_DIR/epic-backfill/<tenant>-<utc>
# @param SPEC_DIR (optional) - specs root; default $APP_PATH/csi-spl-doc/specs
# @param ISSUE_LIMIT (optional) - list page size 1..500, default 50
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 ./run -a do_spl_issue_epic_backfill
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 ISSUE_BACKFILL_LIMIT=100 DRY_RUN=0 ./run -a do_spl_issue_epic_backfill
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 ISSUE_BACKFILL_CMD=verify ./run -a do_spl_issue_epic_backfill
#------------------------------------------------------------------------------
do_spl_issue_epic_backfill() {
  local dry=1 cmd="${ISSUE_BACKFILL_CMD:-plan}" lim="${ISSUE_BACKFILL_LIMIT:-100}" dir all rc=0
  local py="${PROJ_PATH:?}/src/bash/scripts/issue-epic-backfill.py"
  local specs="${SPEC_DIR:-${APP_PATH:-$PROJ_PATH/..}/csi-spl-doc/specs}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "$cmd" == plan || "$cmd" == verify ]] || { do_log "FATAL ISSUE_BACKFILL_CMD must be plan or verify, got: '$cmd'"; return 1; }
  [[ "$lim" =~ ^[0-9]+$ ]] || { do_log "FATAL ISSUE_BACKFILL_LIMIT must be a number (0 = all), got: '$lim'"; return 1; }
  [[ -d "$specs" ]] || { do_log "FATAL SPEC_DIR is not a directory: '$specs'"; return 1; }
  if [[ ",${ISSUE_BACKFILL_SKIP-e2e}," == *",${TENANT_ID:-},"* ]]; then
    do_log "OK ${TENANT_ID:-} is in ISSUE_BACKFILL_SKIP (${ISSUE_BACKFILL_SKIP-e2e}): left alone"
    return 0
  fi
  spl_issue_limit_or 50 >/dev/null || return 1
  # do_spl_desk_cnf sets SPL_STATE_DIR, which the default plan dir needs
  spl_desk_issue_once >&2 || return 1
  all="$(mktemp)"
  spl_epic_autoclose_fetch "$all" || { rm -f "$all"; return 1; }
  if [[ "$cmd" == verify ]]; then
    python3 "$py" verify --list "$all" --specs "$specs" --tenant "$TENANT_ID" || rc=1
    rm -f "$all"
    return $rc
  fi
  dir="${ISSUE_PLAN_DIR:-${SPL_STATE_DIR}/epic-backfill/${TENANT_ID}-$(date -u +%Y%m%dT%H%M%SZ)}"
  (umask 077; mkdir -p "$dir") || { rm -f "$all"; return 1; }
  if (umask 077; python3 "$py" plan --list "$all" --specs "$specs" --tenant "$TENANT_ID" --out-dir "$dir" >"$dir/plan.md"); then
    cat "$dir/plan.md"
    if (( dry )); then
      do_log "OK DRY_RUN nothing was written. PLAN $dir"
    else
      spl_epic_backfill_apply "$dir" "$lim" || rc=1
    fi
  else
    rc=1
  fi
  rm -f "$all"
  return $rc
}

# spl_epic_backfill_create DIR ID: create the planned epic ID (epics.tsv) with
# do_spl_issue_create and print its key.
spl_epic_backfill_create() {
  local dir="$1" id="$2" st disc title desc out key
  IFS=$'\t' read -r _ st disc title desc < <(awk -F'\t' -v id="$id" '$1 == id' "$dir/epics.tsv")
  [[ -n "$title" ]] || { do_log "FATAL no planned epic $id in $dir/epics.tsv" >&2; return 1; }
  out="$(
    unset ISSUE_LABELS ISSUE_PARENT ISSUE_EPIC ISSUE_REF ISSUE_DESCRIPTION_FILE ISSUE_PRIORITY ISSUE_LEVEL \
      ISSUE_ASSIGNEE ISSUE_DEADLINE ISSUE_DISCUSSIONS ISSUE_QAS_ASKED_BY
    [[ -n "$disc" ]] && export ISSUE_DISCUSSIONS="$disc"
    DRY_RUN=0 ISSUE_KIND=epic ISSUE_TITLE="$title" ISSUE_STATUS="$st" ISSUE_DESCRIPTION="$desc" do_spl_issue_create
  )" || { do_log "FATAL could not create epic '$title': $out" >&2; return 1; }
  key="$(printf '%s\n' "$out" | python3 -c 'import json, sys
for line in reversed(sys.stdin.read().splitlines()):
    if line.startswith("{"):
        res = json.loads(line).get("result") or {}
        print(((res.get("issue") if isinstance(res, dict) else None) or {}).get("key") or "")
        break')"
  [[ -n "$key" ]] || { do_log "FATAL epic '$title' was filed but its key is not in the reply: $out" >&2; return 1; }
  do_log "OK created epic $key ($st): $title" >&2
  printf '%s\n' "$key"
}

# spl_epic_backfill_link KEY EPIC: move the issue under the epic.
spl_epic_backfill_link() {
  local out
  out="$(
    unset ISSUE_TITLE ISSUE_DESCRIPTION ISSUE_DESCRIPTION_FILE ISSUE_STATUS ISSUE_PRIORITY ISSUE_LEVEL ISSUE_ASSIGNEE \
      ISSUE_LABELS ISSUE_DEADLINE ISSUE_PARENT ISSUE_KIND ISSUE_QAS_ASKED_BY
    DRY_RUN=0 ISSUE_REF="$1" ISSUE_EPIC="$2" do_spl_issue_update
  )" || { do_log "FATAL $1 -> $2: $out"; return 1; }
  [[ "$out" != *'"epic_closed"'* ]] || do_log "WARN linking $1 closed epic $2 (the hub's SPL-1729 auto-close)"
  do_log "OK $1 -> $2"
}

# spl_epic_backfill_apply DIR LIMIT: the links of links.tsv in order, each new
# epic created right before its first link, at most LIMIT links (0 = all).
spl_epic_backfill_apply() {
  local dir="$1" lim="$2" undo="$1/undo.sh" key target n=0 fail=0 k
  local -A made=()
  (umask 077
    printf '#!/bin/bash\n# undo do_spl_issue_epic_backfill (%s): each linked issue back to no epic\n' "$dir" >"$undo") || return 1
  while IFS=$'\t' read -r key _ target _; do
    [[ -n "$key" ]] || continue
    (( lim == 0 || n < lim )) || break
    if [[ "$target" == new:* ]]; then
      if [[ -z "${made[$target]:-}" ]]; then
        k="$(spl_epic_backfill_create "$dir" "$target")" || { fail=$((fail + 1)); break; }
        made[$target]="$k"
        printf '# created epic %s (planned %s): delete it by hand once its issues are unlinked\n' "$k" "$target" >>"$undo"
      fi
      target="${made[$target]}"
    fi
    if spl_epic_backfill_link "$key" "$target"; then
      printf 'cd %q && ENV=%q TENANT_ID=%q DESK_AGENT=%q ISSUE_REF=%q ISSUE_EPIC= DRY_RUN=0 ./run -a do_spl_issue_update\n' \
        "$PROJ_PATH" "$ENV" "$TENANT_ID" "$DESK_AGENT" "$key" >>"$undo"
      n=$((n + 1))
    else
      fail=$((fail + 1))
    fi
  done <"$dir/links.tsv"
  do_log "UNDO $undo"
  (( fail == 0 )) || { do_log "FATAL linked $n, $fail failed (above)"; return 1; }
  do_log "OK linked $n issues, created ${#made[@]} epics; re-run for the rest (a run with nothing left plans 0 links)"
}
