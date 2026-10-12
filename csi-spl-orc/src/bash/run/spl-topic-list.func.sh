#!/bin/bash
#------------------------------------------------------------------------------
# @description The topics of one channel, as a desk agent sees them (t1
# @description 1457bb6f): `spool topics --as <agent> --channel <c> --json`
# @description through the desk box's own spool, whose hub session the box
# @description key signs. One line of JSON {env, tenant, box, agent, channel,
# @description topics: [{task_id, subject, last_ts}], next}, newest activity
# @description first, no bodies. The hub lists only a channel the agent is
# @description seated in on that box; any other channel lists 0 topics.
# @description Read-only, but like every desk action it calls the hub only
# @description with DRY_RUN=0.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant the desk is seated in
# @param CHANNEL - required: the channel, with or without its #
# @param DESK_AGENT - required: the agent the hub reads as (seated on DESK_BOX)
# @param DESK_BOX (optional) - default SPOOL_DESK_BOX of box.env, else box-desk
# @param TOPIC_LIMIT (optional) - page size 1..100, default 50
# @param TOPIC_BEFORE (optional) - the "next" cursor of a previous page
# @param TOPIC_ALL (optional) - 1 = follow "next" to the last page (one document)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 CHANNEL=refactoring DESK_AGENT=c-227 DRY_RUN=0 ./run -a do_spl_topic_list
#------------------------------------------------------------------------------
do_spl_topic_list() {
  local channel="${CHANNEL:-}" lim="${TOPIC_LIMIT:-50}" dry=1
  channel="${channel#\#}"
  [[ "$channel" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] ||
    { do_log "FATAL CHANNEL must be a channel id like refactoring, got: '${CHANNEL:-}'"; return 1; }
  if ! [[ "$lim" =~ ^[1-9][0-9]{0,2}$ ]] || (( lim > 100 )); then
    do_log "FATAL TOPIC_LIMIT must be 1..100, got: '${TOPIC_LIMIT:-}'"; return 1
  fi
  [[ "${TOPIC_ALL:-0}" =~ ^[01]$ ]] || { do_log "FATAL TOPIC_ALL must be 0 or 1, got: '${TOPIC_ALL:-}'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}" agent="${DESK_AGENT:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  local d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: spool topics --as $agent --channel $channel --limit $lim (box $box, tenant $tenant, $SPL_HUB_URL)"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was read. Re-run with DRY_RUN=0."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1
  spl_topic_list_fetch "$d" "$box" "$tenant" "$agent" "$channel" "$lim"
}

# spl_topic_list_fetch <desk dir> <box> <tenant> <agent> <channel> <limit>:
# one page (TOPIC_BEFORE), or every page with TOPIC_ALL=1, printed as one
# document. Each page is one bounded socket frame; pages go to files, never
# argv, so a long channel cannot hit the kernel's argument limit.
spl_topic_list_fetch() {
  local d="$1" box="$2" tenant="$3" agent="$4" channel="$5" lim="$6"
  local cursor="${TOPIC_BEFORE:-}" n=0 page rc
  local -a pages=()
  while true; do
    local -a a=(topics --as "$agent" --channel "$channel" --limit "$lim" --json)
    [[ -n "$cursor" ]] && a+=(--before "$cursor")
    page="$(mktemp)"
    rc=0
    spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- "${a[@]}" >"$page" 2>&1 || rc=$?
    pages+=("$page")
    if (( rc != 0 )); then
      do_log "FATAL spool topics as $agent in #$channel: $(head -c 2000 "$page")"
      rm -f "${pages[@]}"
      return 1
    fi
    n=$((n + 1))
    [[ "${TOPIC_ALL:-0}" == 1 ]] || break
    cursor="$(spl_topic_page_next "$page")" || { rm -f "${pages[@]}"; return 1; }
    [[ -n "$cursor" ]] || break
    if (( n >= 1000 )); then
      do_log "FATAL topic list did not end after $n pages"
      rm -f "${pages[@]}"
      return 1
    fi
  done
  local prc=0
  python3 - "$ENV" "$tenant" "$box" "$agent" "$channel" "${pages[@]}" <<'EOF_PY' || prc=$?
import json, sys
env, tenant, box, agent, channel, *paths = sys.argv[1:]
topics, nxt = [], None
for p in paths:
    try:
        page = json.load(open(p, encoding="utf-8"))
    except ValueError as e:
        sys.exit("spool topics reply is not JSON: %s" % e)
    topics.extend(page.get("topics") or [])
    nxt = page.get("next")
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent, "channel": channel,
                  "topics": topics, "next": nxt}, sort_keys=True))
EOF_PY
  rm -f "${pages[@]}"
  return $prc
}

# spl_topic_page_next FILE -> the page's next cursor, or nothing on the last page.
spl_topic_page_next() {
  python3 - "$1" <<'EOF_PY'
import json, sys
try:
    nxt = json.load(open(sys.argv[1], encoding="utf-8")).get("next")
except (ValueError, AttributeError) as e:
    sys.exit("spool topics reply is not a page: %s" % e)
if nxt:
    print(nxt)
EOF_PY
}
