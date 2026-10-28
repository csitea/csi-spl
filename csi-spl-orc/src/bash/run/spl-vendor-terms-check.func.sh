#!/bin/bash
#------------------------------------------------------------------------------
# @description Monthly vendor terms watch (spec 159 row T9, SPL-4097):
# fetches the nine URLs of spec 159 section 4.1, compares the quoted
# sentences, and opens an issue when one changes or goes missing.
#
# Red control: a page fixture with one quote edited -> issue opened; the same
# fixture unchanged -> none.
#
# @param ENV (optional) - dev (default) or prd
# @param TENANT_ID (optional) - default t1
# @param DESK_AGENT (optional) - default orchestrator seat or c-001
# @param VENDOR_TERMS_SPEC (optional) - default $APP_PATH/csi-spl-doc/specs/159-byo-ai-keys/spec.md
# @param VENDOR_TERMS_EPIC (optional) - default SPL-2398
# @param VENDOR_TERMS_DISCUSSIONS (optional) - default f8f9dfcc-659a-480d-bc7f-1cffd5fb38b9
# @param VENDOR_TERMS_FETCH_CMD (optional, tests) - custom fetcher
# @param VENDOR_TERMS_ISSUE_CMD (optional, tests) - custom issue opener
# @param VENDOR_TERMS_ISSUE_LIST_CMD (optional, tests) - custom issue lister
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_vendor_terms_check
# @example DRY_RUN=0 ./run -a do_spl_vendor_terms_check
#------------------------------------------------------------------------------
do_spl_vendor_terms_check() {
  local dry="${DRY_RUN:-1}"
  local py="${PROJ_PATH:?}/src/bash/scripts/vendor-terms-check.py"
  local spec="${VENDOR_TERMS_SPEC:-${APP_PATH:-$PROJ_PATH/..}/csi-spl-doc/specs/159-byo-ai-keys/spec.md}"
  local epic="${VENDOR_TERMS_EPIC:-SPL-2398}"
  local disc="${VENDOR_TERMS_DISCUSSIONS:-f8f9dfcc-659a-480d-bc7f-1cffd5fb38b9}"
  local tenant="${TENANT_ID:-t1}"
  local agent="${DESK_AGENT:-}"
  if [[ -z "$agent" ]]; then
    agent="$(sed -n 's/^LEASE_ORCH=//p' "${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf" 2>/dev/null | tail -1)"
    [[ -n "$agent" ]] || agent="c-001"
  fi

  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ -f "$py" ]] || { do_log "FATAL $py not found"; return 1; }
  [[ -f "$spec" ]] || { do_log "FATAL spec file not found: $spec"; return 1; }

  local tmp
  tmp="$(mktemp -d)" || return 1

  local out prc=0
  out="$(python3 "$py" --spec "$spec" --report "$tmp/report.json" 2>&1)" || prc=$?

  if (( prc == 0 )); then
    do_log "$out"
    rm -rf "$tmp"
    return 0
  fi

  if [[ ! -f "$tmp/report.json" ]]; then
    do_log "FATAL vendor terms check failed with code $prc: $out"
    rm -rf "$tmp"
    return 1
  fi

  local status
  status="$(python3 "$py" get-field "$tmp/report.json" status 2>/dev/null || true)"
  if [[ "$status" != "changed" ]]; then
    do_log "$out"
    rm -rf "$tmp"
    return 0
  fi

  local title desc
  title="$(python3 "$py" get-field "$tmp/report.json" title)"
  desc="$(python3 "$py" get-field "$tmp/report.json" description)"

  _spl_vendor_terms_query_existing "$tmp/existing.json" "$tenant" "$agent" "$epic"

  local existing_matches=""
  if existing_matches="$(python3 "$py" check-duplicate "$tmp/report.json" "$tmp/existing.json" 2>/dev/null)"; then
    do_log "INFO open issue already exists for vendor terms findings: $existing_matches; skipping duplicate issue"
    rm -rf "$tmp"
    return 0
  fi

  if [[ "$dry" == 1 ]]; then
    do_log "PLAN would open issue: $title"
    do_log "PLAN epic: $epic, discussions: $disc"
    do_log "PLAN description:"
    echo "$desc"
    rm -rf "$tmp"
    return 1
  fi

  _spl_vendor_terms_create_issue "$title" "$epic" "$disc" "$desc" "$tenant" "$agent"
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_spl_vendor_terms_query_existing() {
  local out_file="$1" tenant="$2" agent="$3" epic="$4"
  : >"$out_file"
  if [[ -n "${VENDOR_TERMS_ISSUE_LIST_CMD:-}" ]]; then
    "$VENDOR_TERMS_ISSUE_LIST_CMD" >"$out_file" 2>/dev/null || true
  elif [[ -n "${VENDOR_TERMS_ISSUE_CMD:-}" ]]; then
    "$VENDOR_TERMS_ISSUE_CMD" list >"$out_file" 2>/dev/null || true
  else
    ENV="${ENV:-dev}" TENANT_ID="$tenant" DESK_AGENT="$agent" ISSUE_ASSIGNEE='' \
      ISSUE_EPIC="$epic" ISSUE_STATUS="eval,todo,wip,blocked,onhold,qas" DRY_RUN=0 \
      do_spl_issue_list >"$out_file" 2>/dev/null || true
  fi
}

_spl_vendor_terms_create_issue() {
  local title="$1" epic="$2" disc="$3" desc="$4" tenant="$5" agent="$6"
  do_log "ALERT vendor terms changed or missing; opening issue: $title"
  if [[ -n "${VENDOR_TERMS_ISSUE_CMD:-}" ]]; then
    ISSUE_TITLE="$title" \
    ISSUE_EPIC="$epic" \
    ISSUE_DISCUSSIONS="$disc" \
    ISSUE_DESCRIPTION="$desc" \
    ISSUE_PRIORITY="${VENDOR_TERMS_PRIORITY:-2}" \
    ENV="${ENV:-dev}" \
    TENANT_ID="$tenant" \
    DESK_AGENT="$agent" \
    "$VENDOR_TERMS_ISSUE_CMD" create \
      --title "$title" \
      --epic "$epic" \
      --discussions "$disc" \
      --description "$desc" \
      --priority "${VENDOR_TERMS_PRIORITY:-2}"
  else
    ISSUE_TITLE="$title" \
    ISSUE_EPIC="$epic" \
    ISSUE_DISCUSSIONS="$disc" \
    ISSUE_DESCRIPTION="$desc" \
    ISSUE_PRIORITY="${VENDOR_TERMS_PRIORITY:-2}" \
    ENV="${ENV:-dev}" \
    TENANT_ID="$tenant" \
    DESK_AGENT="$agent" \
    DRY_RUN=0 \
    do_spl_issue_create
  fi
  do_log "ISSUE opened for vendor terms change: $title"
  return 1
}
