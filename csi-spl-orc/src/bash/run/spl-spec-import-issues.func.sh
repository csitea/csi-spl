#!/bin/bash
#------------------------------------------------------------------------------
# @description Import git-spec task entries into Issues (SPL-76). One issue per
# @description entry in csi-spl-doc/specs/NNN-*/tasks.md (a cases.tsv register
# @description when that spec has no tasks.md). Title "[NNN <id>] <first
# @description sentence>". Parent is the existing epic titled "Spec NNN - ..."
# @description (never a new epic). Label task, or bug when the entry is a fix
# @description or defect. An indented checklist under a task is a subtask:
# @description its parent is the task issue while the hub still allows that,
# @description and the spec epic once the hub requires every parent to be an
# @description epic. Idempotent on the "[NNN <id>]" prefix: an existing issue
# @description is updated, a second run creates nothing. Dry run unless
# @description DRY_RUN=0. A dry run still lists issues (read-only) so the
# @description report can say would-create and would-update.
# @description SPEC_IMPORT_DOCS=1 also files each spec's other documents
# @description (spec.md, plan.md, research, contracts, checklists ...) as
# @description "doc" issues under its epic, split in parts when long, and
# @description writes the epic's description as their index: issue comments
# @description expire with channel retention, a description does not.
# @param ENV - required on a live run: dev or prd
# @param TENANT_ID - required on a live run
# @param DESK_AGENT - required on a live run: the seated agent id
# @param SPEC_DIR (optional) - specs root; default $APP_PATH/csi-spl-doc/specs
# @param SPEC_IMPORT_SPECS (optional) - comma list of NNN to limit the run
# @param SPEC_IMPORT_LABELS (optional) - comma list of extra labels put on every
# @param SPEC_IMPORT_LABELS   issue this import creates or updates (e.g. security)
# @param SPEC_IMPORT_CREATE_EPIC (optional) - 1 creates a 'Spec NNN - <heading>'
# @param SPEC_IMPORT_CREATE_EPIC   epic for any of this plan's specs that lacks
# @param SPEC_IMPORT_CREATE_EPIC   one (live run only); default 0 leaves it MISSING
# @param SPEC_IMPORT_DOCS (optional) - 1 also imports the spec documents (above);
# @param SPEC_IMPORT_DOCS   with SPEC_IMPORT_CREATE_EPIC=1 a doc-only spec gets its epic
# @param SPEC_IMPORT_REDACT (optional) - comma list of words (a user, a name) replaced
# @param SPEC_IMPORT_REDACT   by <REDACTED>; a first.last@ address always becomes <EMAIL>
# @param SPEC_IMPORT_LIMIT (optional) - max writes this run (0 = all)
# @param SPEC_IMPORT_INTERVAL (optional) - seconds between writes, default 0.25
# @param SPEC_IMPORT_OUT (optional) - where the markdown report is written
# @param SPEC_IMPORT_OFFLINE (optional) - 1 parses and prints only; no hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=GRK-00 SPEC_IMPORT_OUT=/tmp/spec-import.md ./run -a do_spl_spec_import_issues
#------------------------------------------------------------------------------
do_spl_spec_import_issues() {
  local specs="${SPEC_DIR:-${APP_PATH:-}/csi-spl-doc/specs}"
  local py="${PROJ_PATH:?}/src/bash/scripts/spec-import-issues.py"
  local interval="${SPEC_IMPORT_INTERVAL:-0.25}"
  local limit="${SPEC_IMPORT_LIMIT:-0}"
  local only="${SPEC_IMPORT_SPECS:-}"
  local -a onlyarg=() parsearg=()
  [[ -n "$only" ]] && onlyarg=(--only "$only")
  parsearg=("${onlyarg[@]}")
  local extra="${SPEC_IMPORT_LABELS:-}"
  [[ -n "$extra" ]] && parsearg+=(--extra-labels "$extra")
  local -a docarg=()
  [[ "${SPEC_IMPORT_DOCS:-0}" == 1 ]] && docarg+=(--docs)
  [[ -n "${SPEC_IMPORT_REDACT:-}" ]] && docarg+=(--redact "$SPEC_IMPORT_REDACT")
  onlyarg+=("${docarg[@]}")
  parsearg+=("${docarg[@]}")
  [[ -f "$py" ]] || { do_log "FATAL spec-import parser is missing: $py"; return 1; }
  [[ -d "$specs" ]] || { do_log "FATAL SPEC_DIR is not a directory: $specs"; return 1; }
  [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || { do_log "FATAL SPEC_IMPORT_INTERVAL must be seconds, got: '$interval'"; return 1; }
  [[ "$limit" =~ ^[0-9]+$ ]] || { do_log "FATAL SPEC_IMPORT_LIMIT must be a number, got: '$limit'"; return 1; }

  if [[ "${SPEC_IMPORT_OFFLINE:-0}" == 1 ]]; then
    python3 "$py" report --specs "$specs" "${onlyarg[@]}"
    return $?
  fi

  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local work report
  work="$(mktemp -d)"
  report="${SPEC_IMPORT_OUT:-$work/report.md}"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN

  python3 "$py" parse --specs "$specs" "${parsearg[@]}" --out "$work/plan.json" || return 1

  # Read-only listing, EPIC-SCOPED (SPL-963, CLE-001 2026-09-30). The hub filters
  # in memory and returns every match in one frame, so a whole-tenant list of the
  # done set (thousands of rows) overruns the CLI socket ("hub unreachable: socket
  # closed"). One small call for the epics (a handful, all statuses), then the
  # children of each of THIS plan's epics one epic at a time, merged. Every
  # response is bounded by a single spec, so it never breaks the socket, and an
  # existing [NNN id] is still found so it is updated, never duplicated.
  local all_status=eval,todo,wip,diss,blocked,onhold,qas,done
  _spl_spec_list_epics() {
    (
      DRY_RUN=0
      ISSUE_ASSIGNEE=
      ISSUE_KIND=epic
      ISSUE_STATUS="$all_status"
      ISSUE_SORT=number
      unset ISSUE_LABEL ISSUE_EPIC ISSUE_PRIORITY ISSUE_LEVEL ISSUE_REF ISSUE_TITLE
      do_spl_issue_list
    ) >"$work/epics.out"
  }
  do_log "INFO listing epics (read-only) to scope the child list to this plan's specs"
  _spl_spec_list_epics || { do_log "FATAL the epic list failed"; return 1; }

  # SPEC_IMPORT_CREATE_EPIC=1: create the 'Spec NNN - <heading>' epic for any of
  # this plan's specs that has none, then re-list. The importer never invents an
  # epic on its own (a dry run and the default leave it MISSING and print the
  # exact do_spl_issue_create command in the report instead).
  if [[ "${SPEC_IMPORT_CREATE_EPIC:-0}" == 1 ]] && (( dry == 0 )); then
    local mspec mhead ecreated=0
    while IFS=$'\t' read -r mspec mhead; do
      [[ -n "$mspec" ]] || continue
      (
        DRY_RUN=0
        unset ISSUE_LABELS ISSUE_PARENT ISSUE_STATUS ISSUE_DESCRIPTION_FILE ISSUE_REF ISSUE_EPIC
        ISSUE_KIND=epic
        ISSUE_TITLE="Spec $mspec - $mhead"
        export ISSUE_KIND ISSUE_TITLE
        do_spl_issue_create
      ) >/dev/null || { do_log "FATAL could not create epic 'Spec $mspec'"; return 1; }
      do_log "INFO created epic: Spec $mspec - $mhead"
      ecreated=$((ecreated + 1))
    done < <(python3 "$py" missingepics --plan "$work/plan.json" --list "$work/epics.out")
    if (( ecreated > 0 )); then
      do_log "INFO created $ecreated epic(s); re-listing"
      _spl_spec_list_epics || { do_log "FATAL the epic re-list failed"; return 1; }
    fi
  fi

  local -a lists=("$work/epics.out") epicrefs=()
  mapfile -t epicrefs < <(python3 "$py" epics --plan "$work/plan.json" --list "$work/epics.out")
  local ref idx=0
  for ref in "${epicrefs[@]}"; do
    [[ -n "$ref" ]] || continue
    idx=$((idx + 1))
    (
      DRY_RUN=0
      ISSUE_ASSIGNEE=
      ISSUE_EPIC="$ref"
      ISSUE_STATUS="$all_status"
      ISSUE_SORT=number
      unset ISSUE_LABEL ISSUE_KIND ISSUE_PRIORITY ISSUE_LEVEL ISSUE_REF ISSUE_TITLE
      do_spl_issue_list
    ) >"$work/children.$idx.out" || { do_log "FATAL the issue list for epic $ref failed"; return 1; }
    lists+=("$work/children.$idx.out")
  done
  do_log "INFO read $idx epic-scoped list(s); merging"
  python3 "$py" mergelists --out "$work/list.out" "${lists[@]}" || return 1

  python3 "$py" reconcile --plan "$work/plan.json" --list "$work/list.out" --desc "$work/desc" --out "$work/ops.json" || return 1
  mkdir -p "$(dirname "$report")"
  python3 "$py" report --ops "$work/ops.json" --out "$report" || return 1
  cat "$report"

  if (( dry )); then
    do_log "OK DRY_RUN nothing was written. Re-run with DRY_RUN=0. Report: $report"
    return 0
  fi

  local name color rc=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in
      task) color="#2563eb" ;;
      bug) color="#b91c1c" ;;
      subtask) color="#0f766e" ;;
      doc) color="#7c3aed" ;;
      *) color="#6b7280" ;;
    esac
    local out
    out="$(spl_desk_issue label --name "$name" --color "$color" 2>&1)" || rc=$?
    if (( rc != 0 )); then
      if [[ "$out" == *exist* || "$out" == *conflict* ]]; then
        rc=0
      else
        do_log "FATAL label $name: $out"
        return 1
      fi
    else
      do_log "INFO label $name is in the catalogue"
    fi
    rc=0
  done < <(python3 -c 'import json,sys
for n in json.load(open(sys.argv[1], encoding="utf-8"))["needed_labels"]:
    print(n)' "$work/ops.json")

  python3 - "$work/ops.json" "$work/ops.tsv" "$work/keys.tsv" <<'PY' || return 1
import base64, json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
ops = sorted(doc["ops"], key=lambda o: (0 if o["kind"] == "task" else 1, o["spec"], o["id"]))
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    for op in ops:
        if op["action"] == "skip":
            continue
        title = base64.b64encode(op["title"].encode()).decode()
        cols = [op["action"], op["item"], op.get("ref") or "", op.get("parent_key") or "",
                op.get("parent_item") or "", op["status"], ",".join(op["labels"]),
                op["description_path"], op["kind"], title]
        fh.write("\x1f".join(cols) + "\n")
with open(sys.argv[3], "w", encoding="utf-8") as fh:
    for item, key in doc["known_keys"].items():
        fh.write(f"{item}\t{key}\n")
PY

  local n=0 fails=0 action item ref pkey pitem status labels desc kind title_b64 title key out try
  while IFS=$'\x1f' read -r action item ref pkey pitem status labels desc kind title_b64; do
    if (( limit > 0 && n >= limit )); then
      do_log "INFO SPEC_IMPORT_LIMIT=$limit reached; the rest waits for the next run"
      break
    fi
    title="$(printf '%s\n' "$title_b64" | base64 -d)"
    if [[ -z "$pkey" && -n "$pitem" ]]; then
      pkey="$(awk -F '\t' -v k="$pitem" '$1==k {print $2; exit}' "$work/keys.tsv")"
    fi
    if [[ -z "$pkey" && "$kind" != epic ]]; then
      do_log "FATAL $item has no parent to file under"
      fails=$((fails + 1))
      n=$((n + 1))
      continue
    fi
    unset ISSUE_TITLE ISSUE_DESCRIPTION ISSUE_DESCRIPTION_FILE ISSUE_STATUS ISSUE_LABELS \
      ISSUE_PARENT ISSUE_EPIC ISSUE_KIND ISSUE_REF ISSUE_ASSIGNEE ISSUE_PRIORITY \
      ISSUE_LEVEL ISSUE_DEADLINE ISSUE_BODY ISSUE_BODY_FILE
    ISSUE_DESCRIPTION_FILE="$desc"
    export ISSUE_DESCRIPTION_FILE
    # An epic op (SPEC_IMPORT_DOCS) writes the description only: the epic's
    # title, status, labels and place stay the owner's.
    if [[ "$kind" != epic ]]; then
      ISSUE_TITLE="$title"
      ISSUE_STATUS="$status"
      ISSUE_LABELS="$labels"
      ISSUE_PARENT="$pkey"
      export ISSUE_TITLE ISSUE_STATUS ISSUE_LABELS ISSUE_PARENT
    fi
    try=0
    rc=0
    out=""
    while (( try < 3 )); do
      try=$((try + 1))
      if [[ "$action" == create ]]; then
        out="$(do_spl_issue_create 2>&1)" && rc=0 || rc=$?
      else
        ISSUE_REF="$ref"
        export ISSUE_REF
        out="$(do_spl_issue_update 2>&1)" && rc=0 || rc=$?
      fi
      (( rc == 0 )) && break
      sleep "$try"
    done
    if (( rc != 0 )); then
      do_log "FATAL $action $item failed: $(printf '%s\n' "$out" | tail -n 1)"
      fails=$((fails + 1))
      n=$((n + 1))
      continue
    fi
    key="$(printf '%s\n' "$out" | python3 -c '
import json, sys
key = ""
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue
    res = obj.get("result", obj)
    iss = res.get("issue") if isinstance(res, dict) else None
    if isinstance(iss, dict) and iss.get("key"):
        key = iss["key"]
print(key)
')"
    if [[ "$action" == create && -z "$key" ]]; then
      do_log "FATAL $item was created but the reply had no key"
      fails=$((fails + 1))
      n=$((n + 1))
      continue
    fi
    [[ -n "$key" ]] && printf '%s\t%s\n' "$item" "$key" >>"$work/keys.tsv"
    n=$((n + 1))
    do_log "INFO $action $item -> ${key:-$ref}"
    sleep "$interval"
  done <"$work/ops.tsv"

  do_log "INFO spec import wrote $n issue(s), $fails failed. Report: $report"
  (( fails == 0 ))
}
