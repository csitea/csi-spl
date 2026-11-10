#!/bin/bash
#------------------------------------------------------------------------------
# @description The discussion's priority is the source (spec 150 section 3.4
# @description item 4, SPL-4813; owner HUM-10, csitea b0f50875, msg f061e485:
# @description "a cron check every 5 min that the prio is applied from the
# @description discussions to the born by them issues and than to the lanes").
# @description It calls the hub's agent issue op prio-sync (`spool issue
# @description prio-sync`): every open issue takes the highest priority SET on
# @description its linked discussions (the workspace's default discussion
# @description does not count); a lane shows the highest of its issues, and a
# @description queued ask reads its discussion's priority, so both follow. An
# @description issue with no set discussion keeps its own. Run from the
# @description operator workspace's desk (the lease's LEASE_TENANT), the hub
# @description sweeps every workspace. The PUT of a topic's priority applies
# @description it at once; this is the safety net. The last prio change wins,
# @description both ways (v1.3, SPL-5223): an issue's own change that is newer
# @description than its discussions' sets them (the answer's spread list, one
# @description line each: topic workspace, topic, old -> new, issue), and the
# @description sweep never moves such an issue back.
# @description Only the box of the dispatch lease holder acts (the cron runs on
# @description every box), unless TOPIC_PRIO_FORCE=1. Logs one line per issue
# @description (workspace, key, topic, old -> new) and a summary. DRY_RUN=1
# @description (the default) asks the hub for the list and writes nothing.
# @param ENV (optional) - dev or prd; default the lease's LEASE_ENV, else prd
# @param TENANT_ID (optional) - the desk's workspace; default the lease's LEASE_TENANT
# @param DESK_AGENT (optional) - the calling desk agent; default the dispatch lease holder's id
# @param DESK_BOX (optional) - default the box's desk (spl_desk_box_default)
# @param TOPIC_PRIO_FORCE (optional) - 1 runs on a box that is not the dispatch holder's
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_topic_prio_sync
# @example DRY_RUN=0 ./run -a do_spl_topic_prio_sync
#------------------------------------------------------------------------------
# Test seams: spl_desk_issue_run (the hub call) is a function a test replaces.

declare -F spl_owner_digest_box >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-owner-digest-post.func.sh"

do_spl_topic_prio_sync() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" dry=1 holder box hbox out
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  box="$(spl_owner_digest_box "$root")"
  hbox="${holder#*@}"; [[ "$holder" == *@* ]] || hbox="$box"
  if [[ "${TOPIC_PRIO_FORCE:-0}" != 1 && ( -z "$holder" || "$hbox" != "$box" ) ]]; then
    do_log "OK topic-prio-sync: the dispatch holder ${holder:-<none>} is not on this box (${box:-?}); its box applies the priorities"
    return 0
  fi
  export ENV="${ENV:-$(spl_owner_digest_lease_conf "$root" LEASE_ENV prd)}"
  export TENANT_ID="${TENANT_ID:-$(spl_owner_digest_lease_conf "$root" LEASE_TENANT "")}"
  export DESK_AGENT="${DESK_AGENT:-${holder%@*}}"
  [[ -n "$TENANT_ID" && -n "$DESK_AGENT" ]] ||
    { do_log "FATAL topic-prio-sync: no TENANT_ID / DESK_AGENT (LEASE_TENANT in $root/dispatch/lease.conf, the dispatch holder)"; return 1; }
  local -a args=()
  ((dry)) || args=(--apply)
  out="$(spl_desk_issue_run prio-sync "${args[@]}")" ||
    { do_log "FATAL topic-prio-sync: spool issue prio-sync failed in $TENANT_ID ($ENV) as $DESK_AGENT"; return 1; }
  spl_topic_prio_report "$out" "$dry"
}

# spl_topic_prio_report <json> <dry>: one log line per change and the summary.
spl_topic_prio_report() {
  local lines
  lines="$(python3 -c '
import json, sys
d = json.loads(sys.argv[1]); dry = sys.argv[2] == "1"
d = d.get("result", d)
verb = "would move" if dry else "moved"
for c in d.get("spread") or []:
    print("INFO topic-prio-sync: %s %s topic %s %s -> %s (issue %s)" % ("would set" if dry else "set", c["workspace"], c["topic"], c["from"] or "unset", c["to"], c["key"]))
for c in d.get("changes") or []:
    print("INFO topic-prio-sync: %s %s %s %s -> %s (topic %s)" % (verb, c["workspace"], c["key"], c["from"], c["to"], c["topic"]))
ws = d.get("workspaces") or []
print("OK topic-prio-sync: %d issue(s) %s across %d workspace(s); %d open issue(s) link no set discussion and keep their own%s"
      % (len(d.get("changes") or []), verb, len(ws), d.get("unset", 0), " (DRY_RUN: nothing written, re-run with DRY_RUN=0)" if dry else ""))
' "$1" "$2" 2>&1)" || { do_log "FATAL topic-prio-sync: the hub answer does not parse: $lines"; return 1; }
  while IFS= read -r l; do do_log "$l"; done <<<"$lines"
}
