#!/bin/bash
#------------------------------------------------------------------------------
# @description An agent (the dispatcher seat) publishes ONE live blog post on
# @description the workspace owner's ALREADY-CONNECTED LinkedIn, for that
# @description owner (SPL-1855; owner HUM-10, topic f46301d4 msgs 54795a30,
# @description c5ed6345: "you SHOULD be able to push to LinkedIn without me").
# @description   1. POST_ID must be in the live blog index the hub reads
# @description      (<wui>/blog-md/index.json, English): its title, link and
# @description      the commentary LinkedIn will show are printed
# @description   2. DRY_RUN=1 (the default) stops there: nothing is called on
# @description      the hub, nothing is published
# @description   3. DRY_RUN=0 runs `spool marketing-publish <POST_ID> --for
# @description      <FOR_HUM>` on DESK_AGENT's desk root: the box's upload
# @description      token, X-Spool-Requester = FOR_HUM. The hub keeps every
# @description      gate: the workspace in cnf marketing.workspaces and
# @description      switched on, FOR_HUM its owner, the share on FOR_HUM's
# @description      own connected channel, once per post (409 on a repeat).
# @description The share sweep never starts a share; only this, or the
# @description owner's Publish button, does. Never reads or prints a token.
# @description Prints one JSON line (env, tenant, post, for, agent, box,
# @description title, url, dry_run, desk, result).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the marketing workspace (cnf marketing.workspaces)
# @param POST_ID - required: the live blog post id, YYYY-MM-DD-slug
# @param FOR_HUM - required: the workspace owner who connected LinkedIn (HUM-...)
# @param DESK_AGENT - required: the publishing agent's desk seat (the dispatcher)
# @param DESK_BOX (optional) - default the desk box, the same value do_spl_desk_up used
# @param DRY_RUN (optional) - 1 (default) prints what it would publish; 0 publishes
# @example ENV=prd TENANT_ID=spool POST_ID=2026-10-14-a-post FOR_HUM=HUM-10 DESK_AGENT=<agent id> ./run -a do_spl_marketing_publish
# @example ENV=prd TENANT_ID=spool POST_ID=2026-10-14-a-post FOR_HUM=HUM-10 DESK_AGENT=<agent id> DRY_RUN=0 ./run -a do_spl_marketing_publish
#------------------------------------------------------------------------------
do_spl_marketing_publish() {
  do_require_bin python3 curl yq || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local post="${POST_ID:-}" hum="${FOR_HUM:-}" tenant="${TENANT_ID:-}"
  local agent="${DESK_AGENT:-}"
  [[ "$post" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
    { do_log "FATAL POST_ID must be a blog post id (YYYY-MM-DD-slug), got: '$post'"; return 1; }
  [[ "$hum" =~ ^HUM-[A-Za-z0-9_-]+$ ]] ||
    { do_log "FATAL FOR_HUM must be the workspace owner's HUM-... id, got: '$hum'"; return 1; }
  do_spl_desk_cnf || return 1
  local box="${DESK_BOX:-$(spl_desk_box_default)}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  local idx line
  idx="$(curl -fsS --max-time 20 "$SPL_WUI_URL/blog-md/index.json" 2>&1)" ||
    { do_log "FATAL the live blog index $SPL_WUI_URL/blog-md/index.json is unreadable: $idx"; return 1; }
  line="$(_spl_marketing_publish_post "$post" "$SPL_WUI_URL" <<<"$idx")" ||
    { do_log "FATAL $line"; return 1; }
  local title url commentary
  { IFS= read -r title; IFS= read -r url; commentary="$(cat)"; } <<<"$line"
  local hub="$SPL_HUB_URL" d="$SPL_STATE_DIR/desk/$tenant/$box" desk=present
  [[ -d "$d/spool/$agent" ]] || desk=missing
  do_log "INFO post $post \"$title\" is live: $url"
  do_log "INFO LinkedIn commentary: ${commentary//$'\n\n'/ | }"
  if (( dry )); then
    [[ "$desk" == present ]] ||
      do_log "WARN no desk for $agent on $box in $tenant ($d): DRY_RUN=0 needs do_spl_desk_up for it first"
    do_log "INFO DRY_RUN would publish $post on the LinkedIn of $hum in $tenant ($ENV) as $agent@$box"
    _spl_marketing_publish_row "$tenant" "$post" "$hum" "$agent" "$box" "$title" "$url" 1 "$desk" ""
    do_log "OK DRY_RUN nothing was published. Re-run with DRY_RUN=0 to publish."
    return 0
  fi
  [[ "$desk" == present ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1
  local out
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- marketing-publish "$post" --for "$hum" 2>&1)" ||
    { do_log "FATAL marketing-publish $post for $hum in $tenant: $out"; return 1; }
  _spl_marketing_publish_row "$tenant" "$post" "$hum" "$agent" "$box" "$title" "$url" 0 "$desk" "$out"
  do_log "OK $agent published $post on the LinkedIn of $hum in $tenant ($ENV)"
}

# _spl_marketing_publish_post <post> <wui url>: reads the blog index JSON on
# stdin and prints the post's title, its link and the commentary (the hub's
# marketing.BlogArticle, emojis included), one per line (the commentary may
# span lines). Exit 1 with the reason when the post is not live in English.
_spl_marketing_publish_post() {
  python3 -c '
import json, sys
from urllib.parse import quote
post, wui = sys.argv[1], sys.argv[2].rstrip("/")
try:
    idx = json.load(sys.stdin)
except ValueError:
    print("the live blog index is not JSON"); sys.exit(1)
en = (idx.get("locales") or {}).get("en") if isinstance(idx, dict) else None
hit = [p for p in (en or []) if isinstance(p, dict) and p.get("id") == post and str(p.get("title", "")).strip()]
if not hit:
    print("post %s is not in the live English blog index: only a live post is published" % post); sys.exit(1)
p = hit[0]
title, summary = str(p["title"]).strip(), str(p.get("summary", "")).strip()
url = wui + "/blog/" + quote(post, safe="")
print(title)
print(url)
print("\U0001F4DD " + title + "\n\n\U0001F4A1 " + summary + "\n\n\U0001F449 " + url)
' "$1" "$2"
}

# _spl_marketing_publish_row <tenant> <post> <for> <agent> <box> <title> <url>
# <dry 0|1> <desk> <hub answer>: the one JSON line.
_spl_marketing_publish_row() {
  python3 -c '
import json, sys
tenant, post, hum, agent, box, title, url, dry, desk, out = sys.argv[1:11]
try:
    res = json.loads(out) if out else None
except ValueError:
    res = out
print(json.dumps({"env": sys.argv[11], "tenant": tenant, "post": post, "for": hum, "agent": agent, "box": box,
                  "title": title, "url": url, "dry_run": dry == "1", "desk": desk, "result": res}, sort_keys=True, ensure_ascii=False))
' "$@" "$ENV"
}
