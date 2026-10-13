#!/bin/bash
#------------------------------------------------------------------------------
# @description Mark an issue as waiting for the owner (t1 topic fda34661, R5 of
# @description the issue triage 1457bb6f): a step that needs the owner's go or
# @description the owner's hands gets the label `needs-owner` and ONE line in
# @description its description that says what to do:
# @description   **Needs owner** since <ISO-8601 Z>: <the exact command or click>
# @description The rule as code: a change that landed but is not applied, or a
# @description step only the owner can take, is `blocked` + `needs-owner` with
# @description the exact apply command in the issue. An open issue (eval, todo,
# @description wip, onhold) moves to blocked; blocked and qas (waiting for the
# @description owner's acceptance) keep their status; done and diss are
# @description refused. Re-marking keeps the first "since". The daily digest
# @description (do_spl_owner_digest_post) lists every issue marked so.
# @description OWNER_STEP_CLEAR=1 takes the label and the line off again (the
# @description owner did it); the status stays unless ISSUE_STATUS is set.
# @description The issue is read even in a dry run; DRY_RUN=1 (default) prints
# @description the change and writes nothing.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent the desk writes as (the pane's id)
# @param ISSUE_REF - required: the issue key, e.g. SPL-12
# @param OWNER_STEP - required unless OWNER_STEP_CLEAR=1: one line, the exact
# @param   command or click the owner has to make (markdown, `code` allowed)
# @param OWNER_STEP_CLEAR (optional) - 1 removes the label and the line
# @param ISSUE_STATUS (optional) - overrides the status rule above
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_REF=SPL-12 OWNER_STEP='press Go on the (GO) Go poll in /t/<topic>' ./run -a do_spl_issue_needs_owner
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_REF=SPL-12 OWNER_STEP_CLEAR=1 ISSUE_STATUS=qas DRY_RUN=0 ./run -a do_spl_issue_needs_owner
#------------------------------------------------------------------------------
SPL_NEEDS_OWNER_LABEL=needs-owner
SPL_NEEDS_OWNER_COLOR="#b45309"

do_spl_issue_needs_owner() {
  spl_issue_check_ref || return 1
  spl_issue_check_fields || return 1
  local clear="${OWNER_STEP_CLEAR:-0}" step="${OWNER_STEP:-}" dry=1
  [[ "$clear" == 0 || "$clear" == 1 ]] || { do_log "FATAL OWNER_STEP_CLEAR must be 0 or 1, got: '$clear'"; return 1; }
  if [[ "$clear" == 0 ]]; then
    [[ -n "${step//[[:space:]]/}" ]] || { do_log "FATAL OWNER_STEP must carry the exact command or click (or OWNER_STEP_CLEAR=1)"; return 1; }
    [[ "$step" != *$'\n'* ]] || { do_log "FATAL OWNER_STEP must be ONE line"; return 1; }
  fi
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local work rc=0
  work="$(mktemp -d)" || return 1
  spl_needs_owner_run "$work" "$clear" "$step" "$dry" || rc=$?
  rm -rf "$work"
  return $rc
}

# spl_needs_owner_run <work dir> <clear> <step> <dry>: read, plan, write.
spl_needs_owner_run() {
  local work="$1" clear="$2" step="$3" dry="$4" labels status
  spl_desk_issue_run get --ref "$ISSUE_REF" >"$work/get.json" || return 1
  spl_needs_owner_plan "$work" "$clear" "$step" "${ISSUE_STATUS:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  { IFS= read -r labels; IFS= read -r status; } <"$work/plan"
  if [[ -s "$work/same" ]]; then
    echo "OK $ISSUE_REF: already $(cat "$work/same"), nothing to change"
    return 0
  fi
  echo "$( ((dry)) && echo PLAN || echo DO) $ISSUE_REF: labels [$labels], status $status, description line:"
  grep -E '^\*\*Needs owner\*\* since ' "$work/desc" | sed 's/^/  /' || echo "  (none: removed)"
  if ((dry)); then
    do_log "OK DRY_RUN nothing was written. Re-run with DRY_RUN=0."
    return 0
  fi
  [[ "$clear" == 1 ]] || spl_needs_owner_label || return 1
  ISSUE_LABELS="$labels" ISSUE_STATUS="$status" ISSUE_DESCRIPTION_FILE="$work/desc" DRY_RUN=0 \
    do_spl_issue_update || return 1
}

# spl_needs_owner_label: the label is in the tenant's catalogue (an existing
# one is fine, the hub answers label_exists).
spl_needs_owner_label() {
  local out rc=0
  out="$(DRY_RUN=0 spl_desk_issue label --name "$SPL_NEEDS_OWNER_LABEL" --color "$SPL_NEEDS_OWNER_COLOR" 2>&1)" || rc=$?
  ((rc == 0)) && return 0
  [[ "$out" == *exist* || "$out" == *conflict* ]] && return 0
  do_log "FATAL label $SPL_NEEDS_OWNER_LABEL: $out"
  return 1
}

# spl_needs_owner_plan <work> <clear> <step> <status override> <now>: from
# <work>/get.json writes <work>/plan (labels csv, status), <work>/desc (the
# new description) and, when nothing would change, <work>/same.
spl_needs_owner_plan() {
  python3 - "$@" "$SPL_NEEDS_OWNER_LABEL" <<'PY'
import json, re, sys
work, clear, step, override, now, label = sys.argv[1:7]
doc = json.load(open(f"{work}/get.json", encoding="utf-8"))
res = doc.get("result", doc) if isinstance(doc, dict) else {}
issue = res.get("issue", res) if isinstance(res, dict) else {}
if not isinstance(issue, dict) or not issue.get("key"):
    sys.exit(f"FATAL no issue in the hub's answer: {json.dumps(doc)[:300]}")
status = issue.get("status", "")
labels = [l for l in (issue.get("labels") or []) if l != label]
desc = issue.get("description") or ""
rx = re.compile(r"^\*\*Needs owner\*\* since (\S+Z): (.*)$", re.M)
old = rx.search(desc)
body = rx.sub("", desc).rstrip()
if clear == "1":
    new_status = override or status
    new_desc = body
else:
    if status in ("done", "diss"):
        sys.exit(f"FATAL {issue['key']} is {status}: a closed issue waits for nobody")
    labels.append(label)
    new_status = override or ("blocked" if status in ("eval", "todo", "wip", "onhold") else status)
    since = old.group(1) if old else now
    line = f"**Needs owner** since {since}: {step.strip()}"
    new_desc = f"{body}\n\n{line}" if body else line
same = (sorted(labels) == sorted(issue.get("labels") or []) and new_status == status
        and new_desc.rstrip() == desc.rstrip())
open(f"{work}/plan", "w", encoding="utf-8").write(f"{','.join(labels)}\n{new_status}\n")
open(f"{work}/desc", "w", encoding="utf-8").write(new_desc + "\n")
if same:
    open(f"{work}/same", "w", encoding="utf-8").write(
        "cleared" if clear == "1" else f"{label} with the same step")
PY
}
