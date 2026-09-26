#!/bin/bash
#------------------------------------------------------------------------------
# @description Post, from a desk agent's pane, a NEW topic into a channel - the
# @description agent's broadcast, the same thing a human does from the WUI
# @description composer (specs/038). do_spl_desk_reply answers inside a topic
# @description a human opened; this one starts the topic.
# @description   1. `spool put-file` for each DESK_FILES path (optional)
# @description   2. `spool send --from <agent> --channel <channel> --kind <kind>`:
# @description      msg.to ALL-0, to_box box-wui, the channel signed into the
# @description      envelope; the hub stores it as a level-1 topic of the
# @description      channel, shows it in every member's browser and delivers it
# @description      to every OTHER member agent. The poster never reads it back.
# @description The hub refuses a channel the agent is not a member of exactly
# @description like one that does not exist (unknown_channel, 404): add the
# @description agent in the WUI (channel -> Agents) first.
# @description Prints one JSON line (env, tenant, box, agent, channel, kind,
# @description the send result). No secret is read. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the posting agent id (the pane's id)
# @param DESK_CHANNEL - required: the channel id, e.g. spool-hub-devel ('#' and
# @param   upper case are accepted and normalized)
# @param DESK_BODY - required: the post text (markdown renders, no fence needed: csi-spl-doc/doc/help/how-to-post.md)
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DESK_KIND (optional) - note (default) | task | result | blocker | msg
# @param DESK_FILES (optional) - space-separated paths to attach (each put as a blob)
# @param DESK_TYPED_BY (optional) - HUM-<n>: the human this post speaks for, the
# @param   agent recorded as the typist (specs/036 `spool send --typed-by`). The hub
# @param   refuses it (typed_by_not_bound) unless do_spl_box_operator_grant bound
# @param   that human to the box.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_CHANNEL=spool-hub-devel DESK_BODY='0.5.6 is out' DRY_RUN=0 ./run -a do_spl_desk_post
#------------------------------------------------------------------------------
do_spl_desk_post() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" agent="${DESK_AGENT:-}"
  local body="${DESK_BODY:-}" kind="${DESK_KIND:-note}" channel="${DESK_CHANNEL:-}" typed_by="${DESK_TYPED_BY:-}"
  channel="${channel#\#}"; channel="${channel,,}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ "$channel" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL DESK_CHANNEL must be a channel id (e.g. spool-hub-devel), got: '${DESK_CHANNEL:-}'"; return 1; }
  [[ -n "$body" ]] || { do_log "FATAL DESK_BODY must carry the post text"; return 1; }
  [[ "$kind" =~ ^(note|task|result|blocker|msg)$ ]] || { do_log "FATAL DESK_KIND must be note, task, result, blocker or msg, got: '$kind'"; return 1; }
  [[ -z "$typed_by" || "$typed_by" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL DESK_TYPED_BY must be a HUM-<n> id, got: '$typed_by'"; return 1; }
  local f files=()
  read -r -a files <<<"${DESK_FILES:-}"
  for f in "${files[@]}"; do
    [[ -f "$f" && -r "$f" ]] || { do_log "FATAL DESK_FILES entry is not a readable file: '$f'"; return 1; }
  done

  local hub d
  hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ "$hub" != https:// ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: post a $kind from $agent on $box into #$channel of $tenant${typed_by:+ typed for $typed_by}${files[*]:+ with ${#files[@]} file(s)}"
    [[ -d "$d/spool/$agent" ]] || do_log "INFO DRY_RUN there is no desk for $agent on $box in $tenant yet ($d): do_spl_desk_up seats one"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to post."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  local ids=() put id
  for f in "${files[@]}"; do
    put="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- put-file "$f" 2>&1)" ||
      { do_log "FATAL put-file $f: $put"; return 1; }
    id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["file_id"])' "$put" 2>/dev/null)" ||
      { do_log "FATAL put-file $f returned no file_id: $put"; return 1; }
    ids+=(--file-id "$id")
  done

  local sent rc=0
  [[ -n "$typed_by" ]] && ids+=(--typed-by "$typed_by")
  sent="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- send --from "$agent" --channel "$channel" \
    --kind "$kind" --body "$body" "${ids[@]}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    [[ "$sent" == *unknown_channel* ]] &&
      do_log "FATAL $agent is not a member of #$channel in $tenant (or it does not exist): add the agent to the channel first"
    [[ "$sent" == *typed_by_not_bound* ]] &&
      do_log "FATAL $typed_by is not bound as operator of $box in $tenant: run do_spl_box_operator_grant first"
    do_log "FATAL send $agent -> #$channel: $sent"
    return 1
  fi
  python3 - "$ENV" "$tenant" "$box" "$agent" "$channel" "$kind" "$typed_by" "$sent" <<'EOF_PY'
import json, sys
env, tenant, box, agent, channel, kind, typed_by, sent = sys.argv[1:]
try:
    sent = json.loads(sent)
except ValueError:
    pass
out = {"env": env, "tenant": tenant, "box": box, "agent": agent,
       "channel": channel, "kind": kind, "send": sent}
if typed_by:
    out["typed_by"] = typed_by
print(json.dumps(out, sort_keys=True))
EOF_PY
  do_log "OK $agent posted a new topic into #$channel ($kind); every other member reads it"
}
