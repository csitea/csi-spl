#!/bin/bash
#------------------------------------------------------------------------------
# @description Reconcile imported spec issues to csi-spl-doc/specs/*/tasks.md
# @description (tasks.md is the list of record for now). Reads those files from
# @description origin/master (SPEC_DIR overrides, for a fixture). Matches each
# @description issue by the same [NNN <id>] prefix do_spl_spec_import_issues
# @description files, including that importer's .sN subtask ids. A checkbox
# @description [x] whose issue is still open is set to done with the comment
# @description "closed by tasks.md reconcile (<spec>/tasks.md:<line>, <sha>)".
# @description A task that is unticked, partial, gone, or marked done without
# @description a checkbox is reported and never written: an issue is never
# @description reopened, and an issue that was not imported from a tasks.md
# @description (no prefix, a doc import, a foreign id) is not in the table.
# @description DRY_RUN=1 (the default) prints the table and the counts.
# @description DRY_RUN=0 applies the closes, then writes a journal and one
# @description undo command that puts each issue back.
# @description The contract of this action is this header.
# @param ENV - required on a live run and on an apply: dev or prd
# @param TENANT_ID - required on a live run and on an apply
# @param DESK_AGENT - required on a live run and on an apply: the seated agent
# @param SPEC_DIR (optional) - a specs root to read instead of origin/master
# @param SPEC_RECONCILE_REF (optional) - git ref to read, default origin/master
# @param SPEC_RECONCILE_SHA (optional) - the sha named in the comment; default
# @param SPEC_RECONCILE_SHA   the resolved ref, or "fixture" when SPEC_DIR is set
# @param SPEC_RECONCILE_LIST (optional) - issue-list JSON; required when
# @param SPEC_RECONCILE_LIST   SPEC_RECONCILE_OFFLINE=1, else the hub is listed
# @param SPEC_RECONCILE_OFFLINE (optional) - 1: no hub read and no re-read
# @param SPEC_RECONCILE_OUT (optional) - the TSV table; default under SPL_STATE_DIR
# @param SPEC_RECONCILE_INTERVAL (optional) - seconds between writes, default 0.25
# @param SPEC_RECONCILE_LIMIT (optional) - max closes this run (0 = all)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 SPEC_RECONCILE_OUT=/tmp/tasks-reconcile.tsv ./run -a do_spl_spec_tasks_reconcile
#------------------------------------------------------------------------------
do_spl_spec_tasks_reconcile() {
  local dry=1 interval limit
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  interval="${SPEC_RECONCILE_INTERVAL:-0.25}"
  limit="${SPEC_RECONCILE_LIMIT:-0}"
  [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || { do_log "FATAL SPEC_RECONCILE_INTERVAL must be seconds, got: '$interval'"; return 1; }
  [[ "$limit" =~ ^[0-9]+$ ]] || { do_log "FATAL SPEC_RECONCILE_LIMIT must be a number, got: '$limit'"; return 1; }
  if [[ "${SPEC_RECONCILE_OFFLINE:-0}" != 1 || "$dry" == 0 ]]; then
    _spl_tasks_reconcile_check_desk || return 1
  fi
  if (( dry == 0 )) && [[ -z "${SPL_STATE_DIR:-}" ]]; then
    do_log "FATAL SPL_STATE_DIR must be set so the journal and the undo have a home"
    return 1
  fi

  local work py import_py table counts
  work="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'; trap - RETURN" RETURN
  py="${PROJ_PATH:?}/src/bash/scripts/spec-tasks-reconcile.py"
  import_py="${PROJ_PATH:?}/src/bash/scripts/spec-import-issues.py"
  [[ -f "$py" && -f "$import_py" ]] || { do_log "FATAL reconcile scripts are missing under $PROJ_PATH"; return 1; }

  local specs sha
  _spl_tasks_reconcile_specs "$work" || return 1
  specs="$RECON_SPECS"
  sha="$RECON_SHA"

  python3 "$import_py" parse --specs "$specs" --out "$work/plan.json" || return 1
  if [[ "${SPEC_RECONCILE_OFFLINE:-0}" == 1 ]]; then
    if [[ -z "${SPEC_RECONCILE_LIST:-}" || ! -r "$SPEC_RECONCILE_LIST" ]]; then
      do_log "FATAL SPEC_RECONCILE_LIST must be a readable issue-list JSON"
      return 1
    fi
    cp -- "$SPEC_RECONCILE_LIST" "$work/list.out" || return 1
  else
    declare -F _spl_spec_list_epics >/dev/null || { do_log "FATAL the spec importer's list helpers are not loaded"; return 1; }
    local all_status=eval,todo,wip,diss,blocked,onhold,qas,done
    do_log "INFO listing epics (read-only) to scope the child list to the spec epics"
    _spl_spec_list_epics "$work" "$all_status" || { do_log "FATAL the epic list failed"; return 1; }
    _spl_spec_list_children "$import_py" "$work" "$all_status" || return 1
  fi

  table="$(_spl_tasks_reconcile_table_path)" || return 1
  counts="$work/counts.txt"
  python3 "$py" --plan "$work/plan.json" --list "$work/list.out" --specs "$specs" \
    --sha "$sha" --table "$work/table.tsv" --close "$work/close.tsv" >"$counts" || return 1
  mkdir -p "$(dirname "$table")" || return 1
  cp -- "$work/table.tsv" "$table" || return 1
  cat "$counts"
  cat "$table"
  do_log "TABLE $table"

  if (( dry )); then
    do_log "OK DRY_RUN nothing was written. Re-run with DRY_RUN=0."
    return 0
  fi

  _spl_tasks_reconcile_apply "$work" "$interval" "$limit" "$sha" || return 1
}

# _spl_tasks_reconcile_check_desk: ENV, TENANT_ID and DESK_AGENT, the same
# shape the desk issue actions require, before any read or write.
_spl_tasks_reconcile_check_desk() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd || "${ENV:-}" == self ]] || {
    do_log "FATAL ENV must be dev, prd or self, got: '${ENV:-}'"
    return 1
  }
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || {
    do_log "FATAL TENANT_ID must be a tenant slug, got: '${TENANT_ID:-}'"
    return 1
  }
  [[ -n "${DESK_AGENT:-}" ]] || { do_log "FATAL DESK_AGENT must be set (the agent the desk writes as)"; return 1; }
}

# _spl_tasks_reconcile_specs <work>: RECON_SPECS and RECON_SHA. SPEC_DIR is
# that tree (a fixture). Otherwise every tasks.md on SPEC_RECONCILE_REF is
# materialised under <work>, so a dirty checkout cannot be the list of record.
_spl_tasks_reconcile_specs() {
  local work="$1" repo ref path rel dest
  if [[ -n "${SPEC_DIR:-}" ]]; then
    [[ -d "$SPEC_DIR" ]] || { do_log "FATAL SPEC_DIR is not a directory: $SPEC_DIR"; return 1; }
    RECON_SPECS="$SPEC_DIR"
    RECON_SHA="${SPEC_RECONCILE_SHA:-fixture}"
  else
    repo="${APP_PATH:?APP_PATH must be the repo root}"
    ref="${SPEC_RECONCILE_REF:-origin/master}"
    RECON_SHA="${SPEC_RECONCILE_SHA:-}"
    if [[ -z "$RECON_SHA" ]]; then
      RECON_SHA="$(git -C "$repo" rev-parse --verify "${ref}^{commit}")" || {
        do_log "FATAL cannot resolve $ref in $repo"
        return 1
      }
    fi
    RECON_SPECS="$work/specs"
    mkdir -p "$RECON_SPECS" || return 1
    while IFS= read -r path; do
      [[ "$path" == */tasks.md ]] || continue
      rel="${path#csi-spl-doc/specs/}"
      dest="$RECON_SPECS/$rel"
      mkdir -p "$(dirname "$dest")" || return 1
      git -C "$repo" show "$ref:$path" >"$dest" || { do_log "FATAL git show $ref:$path failed"; return 1; }
    done < <(git -C "$repo" ls-tree -r --name-only "$ref" -- csi-spl-doc/specs)
  fi
  [[ "$RECON_SHA" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL sha must be one token, got: '$RECON_SHA'"; return 1; }
  [[ -n "$(find "$RECON_SPECS" -name tasks.md -print -quit)" ]] || {
    do_log "FATAL no tasks.md under $RECON_SPECS"
    return 1
  }
}

# _spl_tasks_reconcile_table_path -> the TSV that outlives this call.
_spl_tasks_reconcile_table_path() {
  local p dir
  if [[ -n "${SPEC_RECONCILE_OUT:-}" ]]; then
    p="$SPEC_RECONCILE_OUT"
  elif [[ -n "${SPL_STATE_DIR:-}" ]]; then
    dir="$SPL_STATE_DIR/spec-tasks-reconcile"
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" || return 1
    p="$dir/${TENANT_ID:-na}-$(date -u +%Y%m%dT%H%M%SZ).tsv"
  else
    p="$(mktemp)" || return 1
  fi
  mkdir -p "$(dirname "$p")" || return 1
  printf '%s\n' "$p"
}

# _spl_tasks_reconcile_clear_issue_env: a leaked ISSUE_* would ride along on
# the update and overwrite that field. Only the ref, the comment and the
# status of this one close are set, and each is unset when it is done.
_spl_tasks_reconcile_clear_issue_env() {
  unset ISSUE_TITLE ISSUE_DESCRIPTION ISSUE_DESCRIPTION_FILE ISSUE_STATUS \
    ISSUE_PRIORITY ISSUE_LEVEL ISSUE_ASSIGNEE ISSUE_LABELS ISSUE_DEADLINE \
    ISSUE_PARENT ISSUE_EPIC ISSUE_KIND ISSUE_REF ISSUE_BODY ISSUE_BODY_FILE \
    ISSUE_QAS_ASKED_BY
}

# _spl_tasks_reconcile_now <key> -> the issue's status, re-read so a close
# does not overwrite a status someone changed after the list.
_spl_tasks_reconcile_now() {
  local raw
  raw="$(spl_desk_issue_run get --ref "$1")" || return 1
  printf '%s\n' "$raw" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
res = d.get("result", d)
if isinstance(res, str):
    try:
        res = json.loads(res)
    except json.JSONDecodeError:
        res = {}
if not isinstance(res, dict):
    res = {}
inner = res.get("result", res) if isinstance(res.get("result", res), dict) else res
issue = {}
if isinstance(inner, dict):
    issue = inner.get("issue") or {}
if not issue and isinstance(res, dict):
    issue = res.get("issue") or {}
print(issue.get("status") or "")
'
}

# _spl_tasks_reconcile_apply <work> <pause> <limit> <sha>: each close row.
# The journal and the undo appear together; the undo is one command.
_spl_tasks_reconcile_apply() {
  local work="$1" interval="$2" limit="$3" sha="$4"
  local stamp dir journal undo n=0 skip=0 fail=0 started=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$SPL_STATE_DIR/spec-tasks-reconcile"
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" || return 1
  journal="$dir/${TENANT_ID}-${stamp}.journal.tsv"
  undo="$dir/${TENANT_ID}-${stamp}.undo.sh"
  (umask 077
    printf 'key\told_status\tspec\ttask\tline\tsha\tcomment\n' >"$journal"
  ) || return 1
  while IFS=$'\t' read -r key status spec task line comment; do
    [[ "$key" == issue || -z "$key" ]] && continue
    if (( limit > 0 && n >= limit )); then
      do_log "INFO SPEC_RECONCILE_LIMIT=$limit reached; the rest waits for the next run"
      break
    fi
    local rc=0
    _spl_tasks_reconcile_apply_one "$key" "$status" "$spec" "$task" "$line" "$comment" "$journal" "$undo" "$sha" "$started" && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      n=$((n + 1))
      started=1
    elif [[ "$rc" -eq 2 ]]; then
      skip=$((skip + 1))
    else
      fail=$((fail + 1))
    fi
    sleep "$interval"
  done <"$work/close.tsv"
  if (( started )); then
    do_log "JOURNAL $journal"
    do_log "UNDO bash $undo"
  else
    rm -f "$journal"
    do_log "UNDO none"
  fi
  (( fail == 0 )) || { do_log "FATAL closed $n, skipped $skip, failed $fail"; return 1; }
  do_log "OK closed $n issue(s), skipped $skip already closed"
}

# _spl_tasks_reconcile_apply_one: comment, then done. 2 = already closed.
# The undo line is appended only after the status write succeeds.
_spl_tasks_reconcile_apply_one() {
  local key="$1" status="$2" spec="$3" task="$4" line="$5" comment="$6"
  local journal="$7" undo="$8" sha="$9" started="${10}" now
  now="$status"
  if [[ "${SPEC_RECONCILE_OFFLINE:-0}" != 1 ]]; then
    now="$(_spl_tasks_reconcile_now "$key")" || { do_log "FATAL re-read $key failed"; return 1; }
    case "$now" in
      done|diss)
        do_log "INFO $key is $now already: left alone"
        return 2
        ;;
      eval|todo|wip|blocked|onhold|qas) ;;
      *)
        do_log "FATAL $key status '$now' is not an open one"
        return 1
        ;;
    esac
  fi
  _spl_tasks_reconcile_clear_issue_env
  ISSUE_REF="$key"
  ISSUE_BODY="$comment"
  export ISSUE_REF ISSUE_BODY
  do_spl_issue_comment || { do_log "FATAL comment $key failed"; _spl_tasks_reconcile_clear_issue_env; return 1; }
  unset ISSUE_BODY
  ISSUE_STATUS="done"
  export ISSUE_STATUS
  do_spl_issue_update || { do_log "FATAL update $key failed"; _spl_tasks_reconcile_clear_issue_env; return 1; }
  _spl_tasks_reconcile_clear_issue_env
  if [[ "$started" != 1 ]]; then
    (umask 077
      cat >"$undo" <<EOF
#!/bin/bash
# undo do_spl_spec_tasks_reconcile ${TENANT_ID} sha ${sha}
# one command: bash this file. Each issue goes back to the status it had.
set -u
cd $(printf '%q' "$PROJ_PATH") || exit 1
EOF
    ) || return 1
    chmod 700 "$undo" || return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$now" "$spec" "$task" "$line" "$sha" "$comment" >>"$journal"
  printf 'ENV=%q TENANT_ID=%q DESK_AGENT=%q ISSUE_REF=%q ISSUE_STATUS=%q DRY_RUN=0 ./run -a do_spl_issue_update || exit 1\n' \
    "$ENV" "$TENANT_ID" "$DESK_AGENT" "$key" "$now" >>"$undo"
}
