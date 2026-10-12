#!/bin/bash
#------------------------------------------------------------------------------
# @description Soft-archive done issues (rdb 0084) from a desk pane:
# @description `spool issue archive --as <agent> --ref <key>`. ISSUE_REF
# @description archives that one key. ISSUE_STATUS (usually done) pages the
# @description list and archives each done issue. A done epic or feature is
# @description archived only when every child is done or already archived;
# @description an open child skips the epic and is never cascaded. DRY_RUN=1
# @description (the default) lists and prints the count and keys, and archives
# @description nothing. A real run appends the archived keys to a journal.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id)
# @param ISSUE_REF (optional) - one issue key, e.g. SPL-12
# @param ISSUE_STATUS (optional) - bulk filter; done archives the done issues
# @param ISSUE_ASSIGNEE (optional) - bulk only; default everyone (empty)
# @param ISSUE_LIMIT (optional) - list page size 1..500, default 100
# @param ISSUE_ARCHIVE_JOBS (optional) - how many archives run at once, default 4
# @param ISSUE_CASCADE (optional) - 1 adds --cascade on a safe epic, default 0
# @param ISSUE_JOURNAL (optional) - journal path; default $SPL_STATE_DIR/issue-archive/<tenant>-<utc>.keys
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_STATUS=done DRY_RUN=1 ./run -a do_spl_issue_archive
#------------------------------------------------------------------------------
do_spl_issue_archive() {
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_issue_check_fields || return 1
  local plan
  plan="$(mktemp)"
  if [[ -n "${ISSUE_REF:-}" ]]; then
    spl_issue_check_ref || { rm -f "$plan"; return 1; }
    spl_issue_archive_ref "$plan" || { rm -f "$plan"; return 1; }
  elif [[ -n "${ISSUE_STATUS:-}" ]]; then
    spl_issue_archive_bulk "$plan" || { rm -f "$plan"; return 1; }
  else
    do_log "FATAL set ISSUE_REF or ISSUE_STATUS"
    rm -f "$plan"
    return 1
  fi
  spl_issue_archive_finish "$plan" "$dry"
  local rc=$?
  rm -f "$plan"
  return $rc
}

# spl_issue_archive_finish PLAN DRY: print the plan, or archive it and journal the keys.
spl_issue_archive_finish() {
  local plan="$1" dry="$2" n journal rc=0
  n="$(grep -c . "$plan" || true)"
  if (( dry )); then
    do_log "INFO DRY_RUN would archive $n keys"
    cat "$plan"
    do_log "OK DRY_RUN count=$n nothing was archived"
    return 0
  fi
  journal="$(spl_issue_journal_path)" || return 1
  spl_issue_archive_apply "$plan" "$journal" || rc=1
  return $rc
}

# spl_issue_journal_path -> the journal file, created as an empty file's directory.
spl_issue_journal_path() {
  local p="${ISSUE_JOURNAL:-${SPL_STATE_DIR}/issue-archive/${TENANT_ID:-tenant}-$(date -u +%Y%m%dT%H%M%SZ).keys}"
  mkdir -p "$(dirname "$p")" || return 1
  printf '%s\n' "$p"
}

# spl_issue_archive_bulk PLAN: page ISSUE_STATUS and write `issue|epic KEY` lines.
spl_issue_archive_bulk() {
  local plan="$1" lim raw
  local -a args=()
  local assignee="${ISSUE_ASSIGNEE-}" status="${ISSUE_STATUS:-}" v name
  lim="$(spl_issue_limit)" || return 1
  [[ -z "$assignee" ]] || args+=(--assignee "$assignee")
  [[ -z "$status" ]] || args+=(--status "$status")
  for v in PRIORITY:priority LEVEL:level LABEL:label SORT:sort EPIC:epic KIND:kind; do
    name="ISSUE_${v%%:*}"
    [[ -n "${!name:-}" ]] && args+=("--${v#*:}" "${!name}")
  done
  args+=(--limit "$lim")
  raw="$(mktemp)"
  if ! spl_issue_list_fetch "${args[@]}" >"$raw"; then
    rm -f "$raw"
    return 1
  fi
  spl_issue_archive_select "$raw" >"$plan"
  local rc=$?
  rm -f "$raw"
  return $rc
}

# spl_issue_archive_select FILE -> plan lines. A done epic is skipped when any
# child status other than done is still live (archived children are not listed).
spl_issue_archive_select() {
  python3 - "$1" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
res = doc.get("result") if isinstance(doc, dict) else None
if not isinstance(res, dict):
    sys.stderr.write("list result is not an object\n")
    raise SystemExit(1)
epics = {}
for e in res.get("epics") or []:
    if isinstance(e, dict) and e.get("key"):
        epics[e["key"]] = e

def blocked(key):
    e = epics.get(key)
    if not isinstance(e, dict):
        return True
    for st, n in (e.get("counts") or {}).items():
        if st != "done" and isinstance(n, int) and n > 0:
            return True
    total, done = e.get("total"), e.get("done")
    return isinstance(total, int) and isinstance(done, int) and total != done

for i in res.get("issues") or []:
    if not isinstance(i, dict):
        continue
    key, status = i.get("key") or "", i.get("status") or ""
    if not key or status != "done":
        continue
    kind = i.get("kind") or ""
    if kind in ("epic", "feature"):
        if not blocked(key):
            print("epic " + key)
    else:
        print("issue " + key)
PY
}

# spl_issue_archive_ref PLAN: one ISSUE_REF. An epic with an open child is skipped.
spl_issue_archive_ref() {
  local plan="$1" raw kind
  raw="$(mktemp)"
  if ! spl_desk_issue_run get --ref "$ISSUE_REF" >"$raw"; then
    rm -f "$raw"
    return 1
  fi
  kind="$(spl_issue_json_kind "$raw")" || { rm -f "$raw"; return 1; }
  rm -f "$raw"
  if [[ "$kind" == epic || "$kind" == feature ]]; then
    spl_issue_archive_epic_ref "$plan"
    return $?
  fi
  printf 'issue %s\n' "$ISSUE_REF" >"$plan"
}

# spl_issue_json_kind FILE -> the issue's kind.
spl_issue_json_kind() {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
i=(d.get("result") or {}).get("issue") or {}
print(i.get("kind") or "")' "$1"
}

# spl_issue_archive_epic_ref PLAN: children first, then the epic, or nothing if one is open.
spl_issue_archive_epic_ref() {
  local plan="$1" lim kids
  lim="$(spl_issue_limit)" || return 1
  kids="$(mktemp)"
  if ! spl_issue_list_fetch --epic "$ISSUE_REF" --limit "$lim" >"$kids"; then
    rm -f "$kids"
    return 1
  fi
  python3 - "$kids" "$ISSUE_REF" >"$plan" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
ref = sys.argv[2]
issues = (doc.get("result") or {}).get("issues") or []
live = [i for i in issues if isinstance(i, dict) and i.get("key") and i.get("key") != ref]
if any((i.get("status") or "") != "done" for i in live):
    raise SystemExit(0)
for i in live:
    print("issue " + i["key"])
print("epic " + ref)
PY
  local rc=$?
  rm -f "$kids"
  return $rc
}

# spl_issue_archive_apply PLAN JOURNAL: non-epics first, then epics. The journal
# is the keys that archived, in that phase order.
spl_issue_archive_apply() {
  local plan="$1" journal="$2" issues epics rc=0 n casc=""
  issues="$(mktemp)"
  epics="$(mktemp)"
  awk '$1 == "issue" { print $2 }' "$plan" >"$issues"
  awk '$1 == "epic" { print $2 }' "$plan" >"$epics"
  : >"$journal"
  spl_issue_archive_pool archive "$issues" "$journal" || rc=1
  if (( rc == 0 )); then
    [[ "${ISSUE_CASCADE:-0}" == 1 ]] && casc=cascade
    spl_issue_archive_pool archive "$epics" "$journal" "$casc" || rc=1
  fi
  n="$(grep -c . "$journal" || true)"
  if (( rc == 0 )); then
    do_log "OK archived $n keys"
  else
    do_log "INFO archived $n keys before a failure"
  fi
  do_log "JOURNAL $journal"
  cat "$journal"
  rm -f "$issues" "$epics"
  return $rc
}

# spl_issue_archive_pool OP KEYFILE JOURNAL [cascade]: at most ISSUE_ARCHIVE_JOBS at once.
# Named pids only. A bare `wait` (and a bare `wait -n`) also waits for ./run's
# tee process substitutions (run.sh main), and that wait never ends: the issue
# phase archived one key, then the done epics never started.
spl_issue_archive_pool() {
  local op="$1" file="$2" journal="$3" casc="${4:-}"
  local jobs="${ISSUE_ARCHIVE_JOBS:-4}" key fail pid finished
  local -a pids=() live=()
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL ISSUE_ARCHIVE_JOBS must be 1 or more, got: '$jobs'"; return 1; }
  # Parent resolves cnf before any job: the children inherit SPL_DESK_ISSUE_READY.
  spl_desk_issue_once || return 1
  fail="$(mktemp)"
  : >"$fail"
  while IFS= read -r key || [[ -n "$key" ]]; do
    [[ -n "$key" ]] || continue
    spl_issue_archive_one "$op" "$key" "$journal" "$fail" "$casc" &
    pids+=("$!")
    if (( ${#pids[@]} >= jobs )); then
      finished=""
      wait -n -p finished "${pids[@]}" 2>/dev/null || true
      live=()
      for pid in "${pids[@]}"; do
        [[ -n "$finished" && "$pid" == "$finished" ]] && continue
        live+=("$pid")
      done
      pids=()
      if (( ${#live[@]} )); then pids=("${live[@]}"); fi
    fi
  done <"$file"
  if (( ${#pids[@]} )); then wait "${pids[@]}" 2>/dev/null || true; fi
  if [[ -s "$fail" ]]; then
    do_log "FATAL spool issue $op failed for $(tr '\n' ' ' <"$fail")"
    rm -f "$fail"
    return 1
  fi
  rm -f "$fail"
}

# spl_issue_archive_one OP KEY JOURNAL FAIL [cascade]: one spool issue call.
spl_issue_archive_one() {
  local op="$1" key="$2" journal="$3" fail="$4" casc="${5:-}"
  local -a args=(--ref "$key")
  local out rc=0
  [[ "$casc" == cascade ]] && args+=(--cascade)
  out="$(spl_desk_issue_run "$op" "${args[@]}" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    spl_issue_archive_note "$journal" "$key"
    return 0
  fi
  do_log "FATAL spool issue $op $key: $out"
  spl_issue_archive_note "$fail" "$key"
  return 1
}

# spl_issue_archive_note FILE KEY: append one key, safe for the parallel pool.
spl_issue_archive_note() {
  local file="$1" key="$2"
  {
    flock 9
    printf '%s\n' "$key" >>"$file"
  } 9>>"$file.lock"
}
