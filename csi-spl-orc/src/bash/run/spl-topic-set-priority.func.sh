#!/bin/bash
#------------------------------------------------------------------------------
# @description Set a discussion's priority from a desk agent's pane (rounds
# @description rulebook 5.5 F4, SPL-5978): every open issue linked to TOPIC_ID
# @description gets TOPIC_PRIORITY through the do_spl_issue_update path. The
# @description hub's PUT /v1/topics/{task_id}/priority takes a member session
# @description only, so an agent sets it the other way round: an issue's own
# @description priority change sets EVERY discussion the issue links (the
# @description spread, spec 150 3.4 item 4, SPL-5223), and each of those
# @description discussions' other issues and their lanes then follow. One
# @description issue linked to two discussions moves both: that is the owner's
# @description rule, not a side effect. A topic with no open linked issue is
# @description refused (set it in the web UI). The ask of the discussion reads
# @description the new value in the spawn queue. Prints each issue's old -> new
# @description priority, read back from the hub. DRY_RUN=1 (the default) reads
# @description the linked issues and says what it would update; it writes nothing.
# @param ENV (required) - dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param TENANT_ID (required) - the tenant the desk is seated in
# @param DESK_AGENT (required) - the desk agent that acts
# @param TOPIC_ID (required) - the discussion's uuid
# @param TOPIC_PRIORITY (required) - 1 (highest) .. 5 (lowest)
# @param DESK_BOX (optional) - default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=c-002 TOPIC_ID=<uuid> TOPIC_PRIORITY=2 DRY_RUN=0 ./run -a do_spl_topic_set_priority
#------------------------------------------------------------------------------
do_spl_topic_set_priority() {
  local uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  local topic="${TOPIC_ID:-}" prio="${TOPIC_PRIORITY:-}" dry=1 row key old
  [[ "$topic" =~ $uuid ]] || { do_log "FATAL TOPIC_ID must be a topic uuid, got: '$topic'"; return 1; }
  [[ "$prio" =~ ^[1-5]$ ]] || { do_log "FATAL TOPIC_PRIORITY must be 1 (highest) .. 5 (lowest), got: '$prio'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local -a rows=()
  mapfile -t rows < <(spl_topic_linked_issues "$topic")
  [[ "${rows[0]:-}" != ERROR ]] || return 1
  (( ${#rows[@]} )) || { do_log "FATAL no linked issue: set it in the WUI (no open issue links topic $topic)"; return 1; }
  for row in "${rows[@]}"; do
    key="${row%%$'\t'*}" old="${row#*$'\t'}"
    if (( dry )); then
      do_log "INFO DRY_RUN would set $key priority $old -> $prio, and with it topic $topic and every other discussion $key links"
    else
      ( unset "${!ISSUE_@}"; ISSUE_REF="$key" ISSUE_PRIORITY="$prio" DRY_RUN=0 do_spl_issue_update >/dev/null ) ||
        { do_log "FATAL $key: the priority update failed"; return 1; }
    fi
  done
  if (( dry )); then
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_topic_set_priority_readback "$topic" "$prio" "${rows[@]}"
}

# spl_topic_linked_issues TOPIC -> one "KEY<TAB>PRIORITY" line per open issue
# that links TOPIC; the one line "ERROR" when the list read failed.
spl_topic_linked_issues() {
  local raw rc=0
  raw="$(mktemp)"
  spl_issue_list_fetch --status eval,todo,wip,blocked,onhold,qas --limit 500 >"$raw" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL the open issues were not read (spool issue list)" >&2
    rm -f "$raw"; echo ERROR; return 0
  fi
  python3 - "$raw" "$1" <<'EOF_PY' || echo ERROR
import json, sys
path, topic = sys.argv[1], sys.argv[2].lower()
doc = json.load(open(path, encoding="utf-8"))
for i in ((doc.get("result") or {}).get("issues") or []):
    if any((d.get("task_id") or "").lower() == topic for d in (i.get("discussions") or [])):
        print("%s\t%s" % (i["key"], i.get("priority", "")))
EOF_PY
  rm -f "$raw"
}

# spl_topic_set_priority_readback TOPIC PRIO ROW... : read the linked issues
# again and print each one's old -> new; fails when one did not take PRIO.
spl_topic_set_priority_readback() {
  local topic="$1" prio="$2" row key old now a bad=0
  shift 2
  local -a after=()
  mapfile -t after < <(spl_topic_linked_issues "$topic")
  [[ "${after[0]:-}" != ERROR ]] || return 1
  for row in "$@"; do
    key="${row%%$'\t'*}" old="${row#*$'\t'}" now="?"
    for a in "${after[@]}"; do [[ "${a%%$'\t'*}" == "$key" ]] && now="${a#*$'\t'}"; done
    if [[ "$now" == "$prio" ]]; then
      do_log "OK $key priority $old -> $now (topic $topic)"
    else
      do_log "FATAL $key priority reads $now after the update, not $prio (topic $topic)"; bad=1
    fi
  done
  (( bad == 0 ))
}
