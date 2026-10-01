#!/bin/bash
#------------------------------------------------------------------------------
# @description Route every web UI post to the dispatchers, not the orchestrator
# @description (SPEC-spool-fleet-roles.md). The hub delivers a human post to
# @description the channel's ONLINE SUBSCRIBED agents (channel_subscriptions);
# @description the workspace fallback list fires only when none is online. So
# @description a channel the orchestrator sits in and the dispatchers do not
# @description reaches only the orchestrator (measured 2026-10-01: a fresh
# @description owner topic in a 50-agent channel went to CLE-001 alone).
# @description Per seated workspace and per live channel (default ones
# @description included; #issues and the retired #tasks excluded):
# @description   add    - the master + failover dispatchers where they are not
# @description            subscribed (do_spl_channel_agent_add_op's runner,
# @description            ALLOW_DEFAULT_CHANNEL=1)
# @description   remove - the orchestrator's subscriptions (the remove op's
# @description            runner); its desk seat stays, so DMs and @mentions
# @description            still reach it
# @description   DEAD   - REPORT ONLY: subscribed agents on the desk box with no
# @description            live claude process on this box. Nothing is removed
# @description One read per workspace, through ONE proxy session, which the
# @description dry run makes too (read-only) to compute the plan. DRY_RUN=1
# @description (default) prints the plan; DRY_RUN=0 applies it in that session.
# @param ENV - required: dev or prd
# @param DISPATCH_MASTER / DISPATCH_FAILOVER / DISPATCH_ORCH (optional) - as do_spl_dispatch_setup
# @param DISPATCH_TENANTS (optional) - as do_spl_dispatch_setup
# @param DESK_BOX (optional) - the box the agents answer from, default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd ./run -a do_spl_dispatch_subscribe
# @example ENV=prd DISPATCH_TENANTS=t1 DRY_RUN=0 ./run -a do_spl_dispatch_subscribe
#------------------------------------------------------------------------------
do_spl_dispatch_subscribe() {
  spl_dispatch_cnf || return 1
  rm -rf "$SPL_DISPATCH_TMP"
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_DISPATCH_DRY="${DRY_RUN:-1}"
  SPL_DISPATCH_LIVE_IDS=" $(spl_lease_live_ids | tr '\n' ' ') "
  SPL_DISPATCH_SUB_FAILS=0
  spl_dispatch_with_subs spl_dispatch_subscribe_tenant || return 1
  (( SPL_DISPATCH_SUB_FAILS == 0 )) || { do_log "FATAL $SPL_DISPATCH_SUB_FAILS subscription change(s) failed"; return 1; }
  (( SPL_DISPATCH_DRY )) && do_log "OK DRY_RUN nothing was changed - re-run with DRY_RUN=0 to apply the PLAN lines"
  return 0
}

# spl_dispatch_with_subs <fn>: for each workspace, read its channels and
# subscriptions and call <fn> <tenant> <data>. <data> lines:
#   chan|<channel>            one per live channel (defaults included)
#   sub|<channel>|<box>|<agent>|<origin>   one per live subscription
# DISPATCH_SUBS_DIR (<dir>/<tenant>.txt holding those lines) replaces the hub
# DB, for the tests and for an offline look at an export.
spl_dispatch_with_subs() {
  local fn="$1" t rc=0
  if [[ -n "${DISPATCH_SUBS_DIR:-}" ]]; then
    for t in $DISPATCH_TENANTS; do
      [[ -f "$DISPATCH_SUBS_DIR/$t.txt" ]] || { do_log "FATAL no $DISPATCH_SUBS_DIR/$t.txt"; rc=1; continue; }
      "$fn" "$t" "$(cat "$DISPATCH_SUBS_DIR/$t.txt")" || rc=1
    done
    return $rc
  fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_dispatch_with_subs_all "$fn"
}

# Every workspace through the ONE proxy session spl_via_proxy opened: the desk
# cron runs this every tick, and a proxy per workspace cost a start each.
_spl_dispatch_with_subs_all() {
  local fn="$1" t data rc=0
  for t in $DISPATCH_TENANTS; do
    data="$(_spl_dispatch_subs_read "$t")" || { do_log "FATAL could not read the channels of $t"; rc=1; continue; }
    "$fn" "$t" "$data" || rc=1
  done
  return $rc
}

# Read-only: the live channels and live subscriptions of one tenant, with
# SPL_PROXY_DSN set (inside spl_via_proxy). Announce rows on a default channel
# grant nothing since rdb 0036 and are left out, as ChannelMembers does.
_spl_dispatch_subs_read() {
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" <<'SQL'
BEGIN READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT 'chan|' || c.channel_id FROM channels c
 WHERE c.tenant_id = :'tenant' AND c.deleted_at IS NULL AND c.archived_at IS NULL
   AND c.channel_id NOT IN ('issues', 'tasks')
UNION
SELECT 'chan|' || d FROM unnest(ARRAY['lobby', 'alerts', 'feedback']) AS d
ORDER BY 1;
SELECT 'sub|' || s.channel_id || '|' || s.box_id || '|' || s.agent_id || '|' || s.origin
  FROM channel_subscriptions s
  JOIN channels c ON c.tenant_id = s.tenant_id AND c.channel_id = s.channel_id
 WHERE s.tenant_id = :'tenant' AND s.origin <> 'removed'
   AND c.deleted_at IS NULL AND c.archived_at IS NULL
   AND NOT (s.origin = 'announce' AND s.channel_id IN ('lobby', 'alerts', 'feedback'))
 ORDER BY 1;
COMMIT;
SQL
}

# The plan for one workspace; applied when SPL_DISPATCH_DRY=0.
spl_dispatch_subscribe_tenant() {
  local t="$1" data="$2" ch missing a n_ok=0 n_add=0 n_rm=0 n_dead=0 box="$DISPATCH_DESK_BOX" dead obox
  local -a chans=()
  mapfile -t chans < <(sed -n 's/^chan|//p' <<<"$data")
  (( ${#chans[@]} )) || { do_log "FATAL $t: no channel at all - is that the right workspace?"; return 1; }
  for ch in "${chans[@]}"; do
    missing=""
    for a in "$DISPATCH_MASTER" "$DISPATCH_FAILOVER"; do
      spl_dispatch_subbed "$data" "$ch" "$box" "$a" || missing+="${missing:+ }$a"
    done
    if [[ -n "$missing" ]]; then
      n_add=$((n_add + 1))
      echo "PLAN add $t #$ch $missing"
      (( SPL_DISPATCH_DRY )) || _spl_channel_agent_add_op_run "$t" "$ch" "$box" "$missing" 1 ||
        SPL_DISPATCH_SUB_FAILS=$((SPL_DISPATCH_SUB_FAILS + 1))
    fi
    for obox in $(spl_dispatch_boxes_of "$data" "$ch" "$DISPATCH_ORCH"); do
      n_rm=$((n_rm + 1))
      echo "PLAN remove $t #$ch $DISPATCH_ORCH ($obox)"
      (( SPL_DISPATCH_DRY )) || _spl_channel_agent_remove_op_run "$t" "$ch" "$obox" "$DISPATCH_ORCH" ||
        SPL_DISPATCH_SUB_FAILS=$((SPL_DISPATCH_SUB_FAILS + 1))
    done
    [[ -z "$missing" ]] && [[ -z "$(spl_dispatch_boxes_of "$data" "$ch" "$DISPATCH_ORCH")" ]] && n_ok=$((n_ok + 1))
    dead=""
    for a in $(sed -n "s/^sub|$ch|$box|\([^|]*\)|.*/\1/p" <<<"$data"); do
      [[ "$a" == "$DISPATCH_MASTER" || "$a" == "$DISPATCH_FAILOVER" || "$a" == "$DISPATCH_ORCH" ]] && continue
      [[ "$SPL_DISPATCH_LIVE_IDS" == *" $a "* ]] || dead+="${dead:+ }$a"
    done
    [[ -n "$dead" ]] && { n_dead=$((n_dead + 1)); echo "DEAD $t #$ch $dead (no live process on this box; report only)"; }
  done
  echo "SUM  $t: ${#chans[@]} channel(s), $n_ok already right, $n_add to add the dispatchers, $n_rm orchestrator seat(s) to remove, $n_dead with dead subscriptions"
}

# 0 when <agent> on <box> is subscribed to <channel> in <data>.
spl_dispatch_subbed() {
  grep -q "^sub|$2|$3|$4|" <<<"$1"
}

# The boxes on which <agent> is subscribed to <channel>.
spl_dispatch_boxes_of() {
  sed -n "s/^sub|$2|\([^|]*\)|$3|.*/\1/p" <<<"$1" | sort -u
}
