#!/bin/bash
#------------------------------------------------------------------------------
# @description The daily owner digest (t1 topic fda34661, owner HUM-10 msg
# @description 4a5cceb2: "Daily"): ONE post a day in the workspace listing
# @description every open issue labelled `needs-owner` (do_spl_issue_needs_owner),
# @description oldest first: its link, how long it has waited, and the exact
# @description command or click from its "**Needs owner** since ..." line. An
# @description item with no such line says so. Nothing waiting = no post.
# @description It is a digest, never a page: a plain note in a channel, no
# @description mention, no blocker (asks never page the owner).
# @description Run every hour by the box cron row owner-digest; it acts only
# @description   1. on the box of the dispatch lease holder (<SPOOL_ROOT>/
# @description      dispatch/lease), so a fleet of several boxes posts once,
# @description   2. in the cnf hour env.owner_digest.hour (in
# @description      env.owner_digest.timezone),
# @description   3. once a day (a stamp in OWNER_DIGEST_STATE).
# @description It posts as the holder, into env.owner_digest.channel, through
# @description do_spl_desk_post. OWNER_DIGEST_FORCE=1 skips 1..3 (a manual run).
# @description The list is read even in a dry run; DRY_RUN=1 (default) prints
# @description the post and sends nothing.
# @param ENV (optional) - dev or prd; default the lease's LEASE_ENV, else prd
# @param TENANT_ID (optional) - default the lease's LEASE_TENANT
# @param DESK_AGENT (optional) - default the dispatch lease holder's id
# @param OWNER_DIGEST_FORCE (optional) - 1 posts now, whatever the box, hour or stamp
# @param OWNER_DIGEST_STATE (optional) - the stamp file, default
# @param   $XDG_STATE_HOME/csi-spl/owner-digest.last
# @param OWNER_DIGEST_NOW (optional, tests) - the time, epoch seconds
# @param OWNER_DIGEST_POST_FN (optional, tests) - default do_spl_desk_post
# @param OWNER_DIGEST_LIST_FN (optional, tests) - default spl_issue_list_fetch
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_owner_digest_post
# @example OWNER_DIGEST_FORCE=1 DRY_RUN=0 ./run -a do_spl_owner_digest_post
#------------------------------------------------------------------------------
do_spl_owner_digest_post() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" dry=1 force="${OWNER_DIGEST_FORCE:-0}"
  local now="${OWNER_DIGEST_NOW:-$(date +%s)}"
  local state="${OWNER_DIGEST_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/owner-digest.last}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local holder box hbox
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  [[ "$holder" =~ ^[A-Za-z][A-Za-z0-9-]*(@[a-z0-9][a-z0-9-]*)?$ ]] ||
    { [[ "$force" == 1 && -n "${DESK_AGENT:-}" ]] || { echo "OK owner-digest: no dispatch lease holder in $root/dispatch/lease: no post"; return 0; }; }
  box="$(spl_owner_digest_box "$root")"
  hbox="${holder#*@}"; [[ "$holder" == *@* ]] || hbox="$box"
  if [[ "$force" != 1 && "$hbox" != "$box" ]]; then
    echo "OK owner-digest: the dispatch holder $holder is not on this box ($box); its box posts"
    return 0
  fi
  export ENV="${ENV:-$(spl_owner_digest_lease_conf "$root" LEASE_ENV prd)}"
  export TENANT_ID="${TENANT_ID:-$(spl_owner_digest_lease_conf "$root" LEASE_TENANT "")}"
  export DESK_AGENT="${DESK_AGENT:-${holder%@*}}"
  [[ -n "$TENANT_ID" ]] || { do_log "FATAL no TENANT_ID and no LEASE_TENANT in $root/dispatch/lease.conf"; return 1; }
  do_spl_desk_cnf || return 1
  local hour tz chan today
  { IFS= read -r hour; IFS= read -r tz; IFS= read -r chan; } < <(yq -r \
    '.env.owner_digest.hour // "", .env.owner_digest.timezone // "UTC", .env.owner_digest.channel // ""' "$SPL_CNF")
  [[ "$hour" =~ ^([01]?[0-9]|2[0-3])$ && -n "$chan" ]] ||
    { do_log "FATAL env.owner_digest.hour (0..23) and .channel must be set in the $ENV cnf, got hour '$hour' channel '$chan'"; return 1; }
  today="$(TZ="$tz" date -d "@$now" +%F)"
  if [[ "$force" != 1 ]]; then
    if (( 10#$(TZ="$tz" date -d "@$now" +%H) != 10#$hour )); then
      echo "OK owner-digest: not the hour (${hour}:00 $tz)"; return 0
    fi
    if [[ "$(cat "$state" 2>/dev/null)" == "$today" ]]; then
      echo "OK owner-digest: already ran on $today"; return 0
    fi
  fi
  local work rc=0
  work="$(mktemp -d)" || return 1
  spl_owner_digest_run "$work" "$now" "$chan" "$dry" || rc=$?
  rm -rf "$work"
  ((rc == 0 && dry == 0)) || return $rc
  mkdir -p "$(dirname "$state")" && printf '%s\n' "$today" >"$state" || { do_log "WARN cannot write the stamp $state"; return 0; }
}

# spl_owner_digest_run <work> <now> <channel> <dry>: list, render, post.
spl_owner_digest_run() {
  local work="$1" now="$2" chan="$3" dry="$4" n
  local label="${SPL_NEEDS_OWNER_LABEL:-needs-owner}"
  "${OWNER_DIGEST_LIST_FN:-spl_issue_list_fetch}" --label "$label" \
    --status eval,todo,wip,blocked,onhold,qas --limit 500 >"$work/list.json" || return 1
  spl_owner_digest_render "$work/list.json" "$now" "$label" >"$work/body.md" || return 1
  if [[ ! -s "$work/body.md" ]]; then
    echo "OK owner-digest: nothing waits for the owner: no post"; return 0
  fi
  n="$(grep -c '^[0-9]*\. ' "$work/body.md")"
  if ((dry)); then
    echo "PLAN owner-digest: $n item(s), as $DESK_AGENT into #$chan:"
    sed 's/^/  | /' "$work/body.md"
    do_log "OK DRY_RUN nothing was posted. Re-run with DRY_RUN=0."
    return 0
  fi
  DESK_CHANNEL="$chan" DESK_KIND=note DESK_BODY='' DESK_BODY_FILE="$work/body.md" DRY_RUN=0 \
    "${OWNER_DIGEST_POST_FN:-do_spl_desk_post}" || { do_log "FATAL owner-digest: the post failed; the next hourly run retries"; return 1; }
  do_log "OK owner-digest: $n item(s) posted to #$chan as $DESK_AGENT"
}

# spl_owner_digest_render <list.json> <now> <label>: the post on stdout,
# nothing when no open issue carries the label.
spl_owner_digest_render() {
  python3 - "$@" <<'PY'
import json, re, sys
from datetime import datetime, timezone
path, now, label = sys.argv[1], int(sys.argv[2]), sys.argv[3]
doc = json.load(open(path, encoding="utf-8"))
res = doc.get("result", doc) if isinstance(doc, dict) else {}
issues = res.get("issues") or [] if isinstance(res, dict) else []
rx = re.compile(r"^\*\*Needs owner\*\* since (\S+Z): (.*)$", re.M)
def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None
rows = []
for i in issues:
    if label not in (i.get("labels") or []) or i.get("status") in ("done", "diss"):
        continue
    m = rx.search(i.get("description") or "")
    since = m.group(1) if m and ts(m.group(1)) else (i.get("updated_at") or "")
    t = ts(since) or now
    since = datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    step = m.group(2).strip() if m else "no step written in the issue yet (add it with do_spl_issue_needs_owner)"
    rows.append((t, i["key"], i.get("title") or "", since, step))
if not rows:
    sys.exit(0)
rows.sort()
def age(sec):
    sec = max(0, int(sec))
    return f"{sec // 86400} d" if sec >= 86400 else f"{sec // 3600} h"
def short(s, n=90):
    s = " ".join(s.replace("**", "").split())
    return s if len(s) <= n else s[: n - 3].rstrip() + "..."
stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
print(f"## Waiting for you: {len(rows)} step(s)\n")
print(f"The daily list of every `{label}` issue, oldest first ({stamp}). "
      "Each line is a step only you can take; it leaves this list when its issue loses the label.\n")
for n, (t, key, title, since, step) in enumerate(rows, 1):
    print(f"{n}. [{key}](/issues?issue={key}) {short(title)} - waiting **{age(now - t)}** (since {since})")
    print(f"  Step: {step}")
PY
}

# spl_owner_digest_box <root>: this box's tag (SPOOL_BOX_TAG, else box.env).
spl_owner_digest_box() {
  [[ -n "${SPOOL_BOX_TAG:-}" ]] && { echo "$SPOOL_BOX_TAG"; return; }
  sed -n 's/^SPOOL_BOX_TAG=//p' "$1/box.env" 2>/dev/null | tail -1
}

# spl_owner_digest_lease_conf <root> <key> <default>: a value of lease.conf.
spl_owner_digest_lease_conf() {
  local v
  v="$(sed -n "s/^$2=//p" "$1/dispatch/lease.conf" 2>/dev/null | tail -1)"
  echo "${v:-$3}"
}
