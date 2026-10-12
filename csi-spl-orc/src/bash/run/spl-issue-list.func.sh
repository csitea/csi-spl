#!/bin/bash
#------------------------------------------------------------------------------
# @description A desk agent's issues (specs/039 FR-008): `spool issue list --as
# @description <agent>` with the issues-v1 §4 filters. Default: the ones
# @description assigned to the agent itself, open (not done / diss),
# @description Linear's priority order. A real run pages with --limit and
# @description next_cursor so a done list does not close the hub socket.
# @description Read-only, but like every desk action it calls the hub only
# @description with DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent (the pane's id)
# @param ISSUE_ASSIGNEE (optional) - default me; any id, none, or '' for everyone
# @param ISSUE_STATUS (optional) - comma list; default eval,todo,wip,blocked,onhold,qas (the open ones)
# @param ISSUE_PRIORITY ISSUE_LEVEL ISSUE_LABEL ISSUE_EPIC (optional) - comma lists
# @param ISSUE_KIND (optional) - epic | issue
# @param ISSUE_SORT (optional) - priority (default) | level | deadline | updated | created
# @param ISSUE_LIMIT (optional) - page size 1..500, default 100
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DRY_RUN=0 ./run -a do_spl_issue_list
#------------------------------------------------------------------------------
do_spl_issue_list() {
  local -a args=()
  local lim dry=1
  spl_issue_list_args args || return 1
  lim="$(spl_issue_limit)" || return 1
  args+=(--limit "$lim")
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    spl_desk_issue list "${args[@]}"
    return $?
  fi
  spl_issue_list_fetch "${args[@]}"
}

# spl_issue_limit -> the page size (ISSUE_LIMIT, default 100, hub max 500).
spl_issue_limit() {
  local n="${ISSUE_LIMIT:-100}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] && (( n <= 500 )) || {
    do_log "FATAL ISSUE_LIMIT must be 1..500, got: '${ISSUE_LIMIT:-}'"
    return 1
  }
  printf '%s\n' "$n"
}

# spl_issue_list_args ARRAY: the list flags. Assignee defaults to me and
# status to the open ones; an empty value leaves that flag off.
spl_issue_list_args() {
  local -n _out="$1"
  local assignee="${ISSUE_ASSIGNEE-me}" status="${ISSUE_STATUS-eval,todo,wip,blocked,onhold,qas}" v n
  _out=()
  [[ -z "$assignee" ]] || _out+=(--assignee "$assignee")
  [[ -z "$status" ]] || _out+=(--status "$status")
  for v in PRIORITY:priority LEVEL:level LABEL:label SORT:sort EPIC:epic KIND:kind; do
    n="ISSUE_${v%%:*}"
    [[ -n "${!n:-}" ]] && _out+=("--${v#*:}" "${!n}")
  done
  return 0
}

# spl_issue_page_cursor FILE -> the page's next_cursor, or nothing on the last page.
spl_issue_page_cursor() {
  python3 - "$1" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
except ValueError:
    raise SystemExit(0)
res = doc.get("result") if isinstance(doc, dict) else None
cur = res.get("next_cursor") if isinstance(res, dict) else ""
if cur:
    print(cur)
PY
}

# spl_issue_merge_pages FILE...: one list document, issues joined, cursor cleared.
spl_issue_merge_pages() {
  python3 - "$@" <<'PY'
import json, sys
pages = [json.load(open(p, encoding="utf-8")) for p in sys.argv[1:]]
base = pages[0]
res = base.get("result") if isinstance(base, dict) else None
if not isinstance(res, dict):
    json.dump(base, sys.stdout)
    print()
    raise SystemExit(0)
issues = []
for page in pages:
    one = page.get("result") if isinstance(page, dict) else None
    if isinstance(one, dict) and isinstance(one.get("issues"), list):
        issues.extend(one["issues"])
res["issues"] = issues
res["next_cursor"] = ""
base["result"] = res
json.dump(base, sys.stdout, sort_keys=True)
sys.stdout.write("\n")
PY
}

# spl_issue_list_fetch <list flags>: every page, as the one JSON document
# spl_desk_issue prints. This reads even during a dry run, so a bulk archive
# can count keys without archiving any. It stops on an empty next_cursor.
spl_issue_list_fetch() {
  local cursor="" n=0 page
  local -a pages=()
  while true; do
    local -a a=("$@")
    [[ -n "$cursor" ]] && a+=(--cursor "$cursor")
    page="$(mktemp)"
    if ! spl_desk_issue_run list "${a[@]}" >"$page"; then
      rm -f "$page" "${pages[@]}"
      return 1
    fi
    pages+=("$page")
    cursor="$(spl_issue_page_cursor "$page")"
    n=$((n + 1))
    [[ -n "$cursor" ]] || break
    if (( n >= 1000 )); then
      do_log "FATAL issue list did not end after $n pages"
      rm -f "${pages[@]}"
      return 1
    fi
  done
  if (( ${#pages[@]} == 1 )); then
    cat "${pages[0]}"
  else
    spl_issue_merge_pages "${pages[@]}"
  fi
  rm -f "${pages[@]}"
}
