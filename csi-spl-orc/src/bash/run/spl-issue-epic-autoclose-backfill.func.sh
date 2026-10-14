#!/bin/bash
#------------------------------------------------------------------------------
# @description The one-time backfill of SPL-1729 (owner HUM-10, t1 1ccf3a20,
# @description poll 954cd02f "B — Close it automatically"): close the open
# @description epics (kind epic or feature) whose live issues are all closed,
# @description as the hub now does when an epic's last issue closes. An epic
# @description with no issue is never closed. Status: done when any issue is
# @description done, diss when every one was dismissed.
# @description DRY_RUN=1 (the default) prints the plan, one TSV line per epic:
# @description key, new status, issues, done, diss, current status, title.
# @description DRY_RUN=0 comments the reason on each epic, then sets the
# @description status; the hub's epic close (SPL-1643) archives the epic and
# @description its issues. It writes an undo file (0600): the keys for
# @description do_spl_issue_unarchive and one status command per epic.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent the hub reads and writes as
# @param ISSUE_KEYS (optional) - comma list: only those epics, when the rule also selects them
# @param ISSUE_EMPTY_KEYS (optional) - comma list of open epics with NO live issue to close as done too (the hub never does; only a decision names them)
# @param ISSUE_LIMIT (optional) - list page size 1..500, default 50
# @param ISSUE_PLAN (optional) - plan path; default $SPL_STATE_DIR/epic-autoclose/<tenant>-<utc>.plan.tsv
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-456 DRY_RUN=1 ./run -a do_spl_issue_epic_autoclose_backfill
#------------------------------------------------------------------------------
do_spl_issue_epic_autoclose_backfill() {
  local dry=1 plan all rc=0
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_issue_limit_or 50 >/dev/null || return 1
  [[ "${ISSUE_KEYS:-}" =~ ^([A-Z][A-Z0-9]*-[0-9]+(,[A-Z][A-Z0-9]*-[0-9]+)*)?$ ]] ||
    { do_log "FATAL ISSUE_KEYS must be a comma list of keys like SPL-17,SPL-20, got: '${ISSUE_KEYS:-}'"; return 1; }
  [[ "${ISSUE_EMPTY_KEYS:-}" =~ ^([A-Z][A-Z0-9]*-[0-9]+(,[A-Z][A-Z0-9]*-[0-9]+)*)?$ ]] ||
    { do_log "FATAL ISSUE_EMPTY_KEYS must be a comma list of keys like SPL-17,SPL-20, got: '${ISSUE_EMPTY_KEYS:-}'"; return 1; }
  # do_spl_desk_cnf sets SPL_STATE_DIR, which the default plan path needs
  spl_desk_issue_once >&2 || return 1
  plan="${ISSUE_PLAN:-${SPL_STATE_DIR}/epic-autoclose/${TENANT_ID:-tenant}-$(date -u +%Y%m%dT%H%M%SZ).plan.tsv}"
  mkdir -p "$(dirname "$plan")" || return 1
  [[ -n "${ISSUE_PLAN:-}" ]] || chmod 700 "$(dirname "$plan")"
  all="$(mktemp)"
  if spl_epic_autoclose_fetch "$all" && (umask 077; spl_epic_autoclose_select "$all" >"$plan"); then
    do_log "INFO $(grep -c . "$plan" || true) epics to close. PLAN $plan"
    if (( dry )); then
      cat "$plan"
      do_log "OK DRY_RUN nothing was closed"
    else
      spl_epic_autoclose_apply "$plan" || rc=1
    fi
  else
    rc=1
  fi
  rm -f "$all"
  return $rc
}

# spl_epic_autoclose_fetch FILE: every live issue of the tenant, one status
# at a time (small pages), merged into one list document.
spl_epic_autoclose_fetch() {
  local out="$1" lim s page rc
  local -a pages=()
  lim="$(spl_issue_limit_or 50)" || return 1
  spl_desk_issue_once >&2 || return 1
  for s in eval todo wip blocked onhold qas "done" diss; do
    page="$(mktemp)"
    pages+=("$page")
    spl_issue_list_fetch --status "$s" --limit "$lim" >"$page" || { rm -f "${pages[@]}"; return 1; }
  done
  spl_issue_merge_pages "${pages[@]}" >"$out"
  rc=$?
  rm -f "${pages[@]}"
  return $rc
}

# spl_epic_autoclose_select FILE -> the plan TSV: the open epics whose issues
# (every row whose epic is that key) are all closed, at least one.
spl_epic_autoclose_select() {
  python3 - "$1" "${ISSUE_KEYS:-}" "${ISSUE_EMPTY_KEYS:-}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
only = {k for k in sys.argv[2].split(",") if k}
empty = {k for k in sys.argv[3].split(",") if k}
rows = [i for i in ((doc.get("result") or {}).get("issues") or []) if isinstance(i, dict) and i.get("key")]
closed = ("done", "diss")
kids = {}
for i in rows:
    if i.get("epic") and i.get("epic") != i["key"]:
        kids.setdefault(i["epic"], []).append(i.get("status"))
def num(k):
    return int(k.rsplit("-", 1)[1])
for e in sorted((i for i in rows if i.get("kind") in ("epic", "feature")), key=lambda i: num(i["key"])):
    st, ks = e.get("status"), kids.get(e["key"], [])
    if not ks and e["key"] in empty and st not in closed:
        print("\t".join([e["key"], "done", "0", "0", "0", st or "", " ".join(str(e.get("title") or "").split())]))
        continue
    if st in closed or not ks or any(s not in closed for s in ks) or (only and e["key"] not in only):
        continue
    done = sum(1 for s in ks if s == "done")
    new = "done" if done else "diss"
    title = " ".join(str(e.get("title") or "").split())
    print("\t".join([e["key"], new, str(len(ks)), str(done), str(len(ks) - done), st or "", title]))
PY
}

# spl_epic_autoclose_why NEW WAS ISSUES -> the comment on a closed epic.
spl_epic_autoclose_why() {
  local why="every issue under this epic is done or dismissed, so it closes as the hub now closes an epic when its last issue closes"
  [[ "$3" != 0 ]] || why="it has no live issue, and the SPL-1729 backfill decision named it (ISSUE_EMPTY_KEYS)"
  printf 'Closed as %s by the SPL-1729 backfill: %s. Undo: unarchive it and set its status back to %s.' "$1" "$why" "$2"
}

# spl_epic_autoclose_apply PLAN: comment, then the status, one epic at a time;
# the undo file grows as each one closes.
spl_epic_autoclose_apply() {
  local plan="$1" undo="${1%.tsv}.undo.sh" keys="${1%.tsv}.keys" key new was n=0 fail=0 out
  (umask 077
    printf '#!/bin/bash\n# undo do_spl_issue_epic_autoclose_backfill (%s): restore, then each epic back to its old status\n' "$plan" >"$undo"
    printf 'cd %q && ENV=%q TENANT_ID=%q DESK_AGENT=%q ISSUE_KEYS_FILE=%q DRY_RUN=0 ./run -a do_spl_issue_unarchive\n' \
      "$PROJ_PATH" "$ENV" "$TENANT_ID" "$DESK_AGENT" "$keys" >>"$undo"
    : >"$keys") || return 1
  spl_desk_issue_once || return 1
  while IFS=$'\t' read -r key new n_iss _ _ was _; do
    [[ -n "$key" ]] || continue
    if out="$(spl_desk_issue_run comment --ref "$key" \
        --body "$(spl_epic_autoclose_why "$new" "$was" "$n_iss")" 2>&1)" &&
      out="$(spl_desk_issue_run update --ref "$key" --status "$new" 2>&1)"; then
      printf '%s\n' "$key" >>"$keys"
      printf 'cd %q && ENV=%q TENANT_ID=%q DESK_AGENT=%q ISSUE_REF=%q ISSUE_STATUS=%q DRY_RUN=0 ./run -a do_spl_issue_update\n' \
        "$PROJ_PATH" "$ENV" "$TENANT_ID" "$DESK_AGENT" "$key" "$was" >>"$undo"
      do_log "OK $key -> $new"
      n=$((n + 1))
    else
      do_log "FATAL $key: $out"
      fail=$((fail + 1))
    fi
  done <"$plan"
  do_log "UNDO $undo"
  (( fail == 0 )) || { do_log "FATAL closed $n, $fail failed (above)"; return 1; }
  do_log "OK closed $n epics"
}
