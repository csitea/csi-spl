#!/bin/bash
#------------------------------------------------------------------------------
# @description Put every OD seat (orchestrator, master and failover dispatcher)
# @description of every box of the fleet in every channel (SPEC-spool-fleet-
# @description roles.md 2.1; owner 2026-10-03: "Of course every OD should be a
# @description member of every channel because they are the ones to take in
# @description whatever comes and decide what to do."). The hub delivers a human
# @description post to the channel's ONLINE SUBSCRIBED agents
# @description (channel_subscriptions); the workspace fallback list fires only
# @description when none is online. The fleet's boxes: this machine's desk box,
# @description plus, in fleet mode (lease.conf LEASE_FLEET), every box of
# @description LEASE_PRIORITY / _ORCH / _DISPATCH; a box that seats no OD seat
# @description at all in a workspace is not judged there (ABSENT, report only: a
# @description retired ranking entry, or a box whose own desks check flags the
# @description workspace). Which seat answers is the
# @description leases' business (spec 2.1, 3), not the subscription's.
# @description Per seated workspace and per live channel (default ones
# @description included; #issues and the retired #tasks excluded; a
# @description humans-only channel - its people removed every agent, rdb 0206,
# @description SPL-2423 - is skipped and reported HUMANS-ONLY, never added to):
# @description   add    - each OD seat <id>@<box> not subscribed, where the
# @description            workspace's roster has it (do_spl_channel_agent_add_op's
# @description            runner, ALLOW_DEFAULT_CHANNEL=1)
# @description   UNSEATED - REPORT ONLY: an OD seat of a fleet box with no
# @description            roster row in the workspace: the hub refuses its
# @description            subscription until do_spl_desk_up seats it there
# @description   legacy - spec 061 L6: a role's OLD id (CLE-002 for c-002,
# @description            from <spool root>/agent-id-aliases.tsv) is removed
# @description            where the role's new id is already subscribed on
# @description            that box; the old row would be refused after the
# @description            2026-10-03T20:59:59Z cutoff
# @description   DEAD   - REPORT ONLY: subscribed agents on the desk box with no
# @description            live claude process on this box. Nothing is removed
# @description   SILENT - REPORT ONLY (CLE-77876, prd csitea 2026-10-01: two
# @description            days of human posts and not one reached an agent):
# @description            people posted in the workspace's channels in the last
# @description            DISPATCH_SILENCE_WINDOW minutes, and neither
# @description            dispatcher's desk spool received a single file.
# @description            The window starts no earlier than the last change
# @description            of the fleet dispatch holder (spl_dispatch_silence_win)
# @description   UNSIGNED - REPORT ONLY: the hub stored human posts of that
# @description            window unsigned (no box-wui pin), so no box got them;
# @description            a post from before the workspace's current pin does
# @description            not count (that one is do_spl_replay_unsigned's)
# @description            (do_spl_check_box_wui_pins, do_spl_cloud_pin_box_wui).
# @description            #issues, #tasks and #probe are out of both counts
# @description            (the unanswered sweep's channel skip; #probe is the
# @description            live-proof channel). The skip is the channel, not
# @description            the sender (SPL-1648)
# @description One read per workspace, through ONE proxy session, which the
# @description dry run makes too (read-only) to compute the plan. DRY_RUN=1
# @description (default) prints the plan; DRY_RUN=0 applies it in that session.
# @param ENV - required: dev or prd
# @param DISPATCH_MASTER / DISPATCH_FAILOVER / DISPATCH_ORCH (optional) - as do_spl_dispatch_setup
# @param DISPATCH_TENANTS (optional) - as do_spl_dispatch_setup
# @param DISPATCH_FLEET_BOXES (optional) - the fleet's boxes, space or comma separated; default above
# @param DESK_BOX (optional) - the box the agents answer from, default box-desk
# @param DRY_RUN (optional) - 1 (default) or 0
# @param DISPATCH_SILENCE_WINDOW (optional) - minutes, default 120; clipped to the minutes since the fleet dispatch holder last changed
# @param DISPATCH_SILENCE_GRACE (optional) - minutes a post may take to arrive, default 5
# @param DISPATCH_SILENCE_MIN (optional) - human posts it takes to call silence, default 2
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
#   hon|<channel>             one per humans-only channel (rdb 0206): its
#                             people removed every agent; no OD seat is added
#   ros|<box>|<agent>         one per roster row of an OD seat (any box), and
#                             of a role seat 001..003 under any vendor letter:
#                             another box's OD seat (SPL-1756)
#   hum|<posts>|<unsigned>    human channel posts the hub stored between
#                             DISPATCH_SILENCE_WINDOW and _GRACE minutes ago,
#                             and how many of them unsigned and not older
#                             than the live box-wui pin (absent = 0|0).
#                             #issues, #tasks and #probe are in neither number
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
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v ods="$(spl_dispatch_od_ids)" \
    -v rs="^$(spl_dispatch_role_rx)\$" -v win="$(spl_dispatch_silence_win)" -v grace="${DISPATCH_SILENCE_GRACE:-5}" <<'SQL'
BEGIN READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT 'chan|' || c.channel_id FROM channels c
 WHERE c.tenant_id = :'tenant' AND c.deleted_at IS NULL AND c.archived_at IS NULL
   AND c.channel_id NOT IN ('issues', 'tasks')
UNION
SELECT 'chan|' || d FROM unnest(ARRAY['lobby', 'alerts', 'feedback']) AS d
ORDER BY 1;
SELECT 'hon|' || c.channel_id FROM channels c
 WHERE c.tenant_id = :'tenant' AND c.deleted_at IS NULL AND c.archived_at IS NULL
   AND c.humans_only_at IS NOT NULL
 ORDER BY 1;
SELECT 'sub|' || s.channel_id || '|' || s.box_id || '|' || s.agent_id || '|' || s.origin
  FROM channel_subscriptions s
  JOIN channels c ON c.tenant_id = s.tenant_id AND c.channel_id = s.channel_id
 WHERE s.tenant_id = :'tenant' AND s.origin <> 'removed'
   AND c.deleted_at IS NULL AND c.archived_at IS NULL
   AND NOT (s.origin = 'announce' AND s.channel_id IN ('lobby', 'alerts', 'feedback'))
 ORDER BY 1;
SELECT 'ros|' || r.box_id || '|' || r.agent_id FROM roster r
 WHERE r.tenant_id = :'tenant'
   AND (r.agent_id = ANY (string_to_array(:'ods', ' ')) OR r.agent_id ~ :'rs')
 ORDER BY 1;
-- unsigned leaves out a post stored before the live box-wui pin was set: a
-- post stored before the pin is the replay's (do_spl_replay_unsigned), not a
-- live gap (CLE-001, 2026-10-01: the first ticks after the pin alerted).
-- #issues, #tasks and #probe are out of both counts: the unanswered sweep's
-- channel skip. #probe is the live-proof channel. The skip is the channel,
-- not the sender, so a post there does not count whoever sent it (SPL-1648).
SELECT 'hum|' || count(*) || '|' || count(*) FILTER (WHERE m.env_sig = '' AND NOT EXISTS (
         SELECT 1 FROM pins p WHERE p.tenant_id = m.tenant_id AND p.box_id = 'box-wui'
            AND p.revoked_at IS NULL AND p.updated_at > m.received_at))
  FROM messages m
 WHERE m.tenant_id = :'tenant' AND m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%'
   AND m.channel IS NOT NULL AND m.channel NOT IN ('issues', 'tasks', 'probe') AND m.typed_by IS NULL
   AND m.received_at > now() - make_interval(mins => :win)
   AND m.received_at <= now() - make_interval(mins => :grace);
COMMIT;
SQL
}

# The plan for one workspace; applied when SPL_DISPATCH_DRY=0.
spl_dispatch_subscribe_tenant() {
  local t="$1" data="$2" ch missing a old fb n_ok=0 n_add=0 n_leg=0 n_dead=0 box="$DISPATCH_DESK_BOX" dead unseated=""
  local -a chans=()
  grep -q '^chan|' <<<"$data" || { do_log "FATAL $t: no channel at all - is that the right workspace?"; return 1; }
  mapfile -t chans < <(spl_dispatch_chans "$data")
  local hon
  hon="$(sed -n 's/^hon|/#/p' <<<"$data" | tr '\n' ' ')"
  [[ -n "$hon" ]] && echo "HUMANS-ONLY $t ${hon% } (its people removed every agent: no OD seat is added; report only)"
  local boxes absent
  boxes="$(spl_dispatch_served_boxes "$data")"
  absent="$(spl_dispatch_fleet_boxes | grep -vxF -f <(printf '%s\n' $boxes) | tr '\n' ' ')"
  for fb in $boxes; do
    for a in $(spl_dispatch_od_ids); do
      spl_dispatch_rostered "$data" "$fb" "$a" || unseated+="${unseated:+ }$a@$fb"
    done
  done
  for ch in "${chans[@]}"; do
    local right=1
    for fb in $boxes; do
      missing=""
      for a in $(spl_dispatch_od_ids); do
        spl_dispatch_rostered "$data" "$fb" "$a" || { right=0; continue; }
        spl_dispatch_subbed "$data" "$ch" "$fb" "$a" || missing+="${missing:+ }$a"
      done
      [[ -n "$missing" ]] || continue
      right=0 n_add=$((n_add + 1))
      echo "PLAN add $t #$ch $missing ($fb)"
      (( SPL_DISPATCH_DRY )) || _spl_channel_agent_add_op_run "$t" "$ch" "$fb" "$missing" 1 1 ||
        SPL_DISPATCH_SUB_FAILS=$((SPL_DISPATCH_SUB_FAILS + 1))
    done
    for fb in $boxes; do
      for a in $(spl_dispatch_od_ids); do
        old="$(spl_dispatch_legacy_of "$a")"
        [[ -n "$old" ]] && spl_dispatch_subbed "$data" "$ch" "$fb" "$a" && spl_dispatch_subbed "$data" "$ch" "$fb" "$old" || continue
        n_leg=$((n_leg + 1))
        echo "PLAN remove $t #$ch $old ($fb; legacy id of $a, which is subscribed)"
        (( SPL_DISPATCH_DRY )) || _spl_channel_agent_remove_op_run "$t" "$ch" "$fb" "$old" ||
          SPL_DISPATCH_SUB_FAILS=$((SPL_DISPATCH_SUB_FAILS + 1))
      done
    done
    (( right )) && n_ok=$((n_ok + 1))
    dead=""
    for a in $(sed -n "s/^sub|$ch|$box|\([^|]*\)|.*/\1/p" <<<"$data"); do
      spl_dispatch_is_od "$a" && continue
      [[ "$SPL_DISPATCH_LIVE_IDS" == *" $a "* ]] || dead+="${dead:+ }$a"
    done
    [[ -n "$dead" ]] && { n_dead=$((n_dead + 1)); echo "DEAD $t #$ch $dead (no live process on this box; report only)"; }
  done
  [[ -n "${absent// /}" ]] && echo "ABSENT $t ${absent% } (no OD seat of that box in $t: not judged here; report only)"
  [[ -n "$unseated" ]] && echo "UNSEATED $t $unseated (no roster row in $t: seat it with do_spl_desk_up; report only)"
  spl_dispatch_inbound "$t" "$data"
  echo "SUM  $t: ${#chans[@]} channel(s), $n_ok already right, $n_add OD seat add(s), $n_leg legacy role row(s) to remove, $n_dead with dead subscriptions, $(wc -w <<<"$unseated") OD seat(s) unseated"
}

# spl_dispatch_chans <data>: the channels an OD seat belongs in, one per line:
# every chan| line but a humans-only one (hon|, SPL-2423: owner HUM-10
# 2026-10-17, "once the users have removed all of the agents from the
# properties of a channel, no new agents should be added by the system").
spl_dispatch_chans() {
  local d="$1"
  sed -n 's/^chan|//p' <<<"$d" | grep -vxF -f <(sed -n 's/^hon|//p' <<<"$d"; echo '|') || true
}

# The role seat RX (SPL_ROLE_SEAT_RX): the ONE list, spool-env.inc.sh's.
spl_dispatch_role_rx() {
  if [[ -z "${SPL_ROLE_SEAT_RX:-}" ]]; then
    # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
    SPL_ROLE_SEAT_RX="$(source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" >/dev/null 2>&1
      printf '%s' "${SPL_ROLE_SEAT_RX:-}")"
  fi
  printf '%s' "$SPL_ROLE_SEAT_RX"
}

# The OD seats: the orchestrator, the master and the failover dispatcher.
spl_dispatch_od_ids() {
  echo "$DISPATCH_ORCH $DISPATCH_MASTER $DISPATCH_FAILOVER"
}

# 0 when <agent> is an OD seat, or the legacy id of one.
spl_dispatch_is_od() {
  local o
  for o in $(spl_dispatch_od_ids); do
    [[ "$1" == "$o" ]] && return 0
    [[ "$1" == "$(spl_dispatch_legacy_of "$o")" ]] && return 0
  done
  return 1
}

# The fleet's boxes, one per line: DISPATCH_FLEET_BOXES, else this machine's
# desk box plus (fleet mode) every box the lease rankings name.
spl_dispatch_fleet_boxes() {
  local l="${DISPATCH_FLEET_BOXES:-}"
  if [[ -z "$l" ]]; then
    l="$DISPATCH_DESK_BOX"
    [[ -n "${LEASE_FLEET:-}" ]] && l+=",${LEASE_PRIORITY:-},${LEASE_PRIORITY_ORCH:-},${LEASE_PRIORITY_DISPATCH:-}"
  fi
  tr ', ' '\n\n' <<<"$l" | awk 'NF && !seen[$0]++'
}

# The fleet boxes that seat at least one OD seat in the workspace of <data>.
spl_dispatch_served_boxes() {
  local fb a
  for fb in $(spl_dispatch_fleet_boxes); do
    for a in $(spl_dispatch_od_ids); do
      spl_dispatch_rostered "$1" "$fb" "$a" && { echo "$fb"; break; }
    done
  done
}

# 0 when the workspace's roster in <data> has <agent> on <box>.
spl_dispatch_rostered() {
  grep -qx "ros|$2|$3" <<<"$1"
}

# The legacy id an agent id was mapped from (agent-id-aliases.tsv), or nothing.
spl_dispatch_legacy_of() {
  awk -F'\t' -v id="$1" '$2 == id && $1 ~ /^(CLE|GRK|AGY|QWN)-[0-9]+$/ {print $1; exit}' "${SPOOL_ROOT:-/var/spool-hub}/agent-id-aliases.tsv" 2>/dev/null
}

# 0 when <agent> on <box> is subscribed to <channel> in <data>.
spl_dispatch_subbed() {
  grep -q "^sub|$2|$3|$4|" <<<"$1"
}

# The boxes on which <agent> is subscribed to <channel>.
spl_dispatch_boxes_of() {
  sed -n "s/^sub|$2|\([^|]*\)|$3|.*/\1/p" <<<"$1" | sort -u
}

# The silence window in minutes: DISPATCH_SILENCE_WINDOW (default 120), but
# no earlier than the last change of the fleet dispatch holder. The posts
# before it were routed to the previous holder's desk (spec 059 S5), not to
# this one (c-322, prd t1 2026-10-05: sat took dispatch at 08:16:12Z and its
# 08:16:49Z tick counted the previous holder's two hours of posts against
# sat's empty desk: "GAP t1 inbound: 16 human posts in 120 min"). Rewritten
# only on a change (spl_fleet_apply), fleet.dispatch.holder's mtime is the
# takeover.
spl_dispatch_silence_win() {
  local win="${DISPATCH_SILENCE_WINDOW:-120}" f="${SPOOL_ROOT:-/var/spool-hub}/dispatch/fleet.dispatch.holder" at held
  at="$(stat -c %Y "$f" 2>/dev/null)" || { echo "$win"; return 0; }
  held=$(( (${DISPATCH_NOW:-$(date +%s)} - at + 59) / 60 ))
  (( held < 0 )) && held=0
  (( held < win )) && win=$held
  echo "$win"
}

# spl_dispatch_inbound <tenant> <data>: the SILENT / UNSIGNED lines of one
# workspace (none when it is healthy, a test workspace, or not seated here).
# Inbound = files the dispatchers' desk spools received (inbox + archive,
# by mtime: the box writes a file on delivery) since the window opened.
spl_dispatch_inbound() {
  local t="$1" data="$2" posts uns n=0 a d win since
  win="$(spl_dispatch_silence_win)"
  IFS='|' read -r _ posts uns < <(grep '^hum|' <<<"$data" | sed -n 1p)
  posts="${posts:-0}" uns="${uns:-0}"
  spl_test_workspace "$t" && return 0
  (( uns > 0 )) && echo "UNSIGNED $t $uns of $posts human posts in $win min stored unsigned, no agent got them: no box-wui pin, see do_spl_check_box_wui_pins"
  (( posts >= ${DISPATCH_SILENCE_MIN:-2} )) || return 0
  spl_dispatch_seated "$DISPATCH_MASTER" "$t" || spl_dispatch_seated "$DISPATCH_FAILOVER" "$t" || return 0
  since=$(( ${DISPATCH_NOW:-$(date +%s)} - win * 60 ))
  for a in "$DISPATCH_MASTER" "$DISPATCH_FAILOVER"; do
    d="$DISPATCH_STATE_DIR/desk/$t/$DISPATCH_DESK_BOX/spool/$a"
    n=$(( n + $(find "$d/inbox" "$d/archive" -maxdepth 1 -type f -newermt "@$since" 2>/dev/null | wc -l) ))
  done
  (( n == 0 )) && echo "SILENT $t $posts human posts in $win min, 0 inbound files on the dispatchers' desk: the workspace receives nothing"
  return 0
}
