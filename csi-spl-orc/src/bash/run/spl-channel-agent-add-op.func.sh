#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat agents in a channel by INSERT into channel_subscriptions,
# @description the row InviteChannelAgent writes (origin invite), through the
# @description Cloud SQL proxy as the env's project service account. This is
# @description the OPERATOR path. do_spl_channel_agent_add is the other one:
# @description it signs in as a tenant member, which a customer tenant does
# @description not have. Each agent must be on the tenant roster for AGENT_BOX
# @description (else FATAL not_a_member) and the channel must exist and not be
# @description deleted, or the transaction rolls back and no row changes. A
# @description default channel (lobby, alerts, feedback, tasks; general is
# @description lobby) and the reserved issues channel are refused. A seat
# @description whose origin is removed is not a member: it is set back to
# @description invite, which is what InviteChannelAgent's conflict update
# @description does. A seat that is already invite or announce is left as it
# @description is (ON CONFLICT DO NOTHING) and reported as already a member.
# @description The number of seats that end as members must equal the number
# @description of agents asked for, or the transaction rolls back. Values
# @description travel as psql variables (:'var'), never spliced into the SQL.
# @description The statement sets app.tenant_id for the transaction (rdb 0014).
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param CHANNEL - required: the channel id
# @param AGENTS - required: space-separated agent ids, e.g. "CLE-7 CLE-8"
# @param AGENT_BOX (optional) - default box-desk. box-wui is reserved.
# @param ALLOW_DEFAULT_CHANNEL (optional) - 1 seats agents in a default channel
# @param   (lobby, alerts, feedback; general is lobby) the way the hub's
# @param   InviteChannelAgent does since rdb 0036: the channel's row is seeded
# @param   first, then the invite row is written. issues and the retired tasks
# @param   stay refused. Default 0 (refused, as before)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 CHANNEL=release-notes AGENTS="CLE-7 CLE-8" DRY_RUN=0 ./run -a do_spl_channel_agent_add_op
#------------------------------------------------------------------------------
do_spl_channel_agent_add_op() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" ch="${CHANNEL:-}" box="${AGENT_BOX:-$(spl_desk_box_default)}" agents="${AGENTS:-}" dry=1 raw a
  local allowdef="${ALLOW_DEFAULT_CHANNEL:-0}"
  [[ "$allowdef" == 0 || "$allowdef" == 1 ]] || { do_log "FATAL ALLOW_DEFAULT_CHANNEL must be 0 or 1, got: '$allowdef'"; return 1; }
  local -a ids=()
  declare -A seen=()
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$ch" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id, got: '$ch'"; return 1; }
  raw="$ch"
  [[ "$ch" == general ]] && ch=lobby
  case "$ch" in
    issues)
      do_log "FATAL #issues is reserved and is not a channel an agent is added to"
      return 1 ;;
    lobby|alerts|feedback|tasks)
      # a default channel takes invite rows since rdb 0036 (the hub seeds its
      # row first); ALLOW_DEFAULT_CHANNEL=1 opts in. #tasks is retired: never.
      if [[ "$allowdef" == 1 && "$ch" != tasks ]]; then
        :
      elif [[ "$raw" == general ]]; then
        do_log "FATAL #general is #lobby, a default channel (lobby, alerts, feedback, tasks): an agent seat is not stored"
        return 1
      else
        do_log "FATAL #$ch is a default channel (lobby, alerts, feedback, tasks): an agent seat is not stored"
        return 1
      fi ;;
  esac
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL AGENT_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ -n "$agents" ]] || { do_log "FATAL AGENTS must name at least one agent id"; return 1; }
  for a in $agents; do
    [[ "$a" =~ ^[A-Z]{2,4}-[0-9]+$ && "$a" != HUM-* && "${a%%-*}" != BOX ]] || { do_log "FATAL AGENTS entry '$a' is not an agent id"; return 1; }
    [[ -n "${seen[$a]:-}" ]] && continue
    seen[$a]=1
    ids+=("$a")
  done
  agents="${ids[*]}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would add $agents on $box to #$ch in $tenant (origin=invite) on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_channel_agent_add_op_run "$tenant" "$ch" "$box" "$agents" "$allowdef"
}

_spl_channel_agent_add_op_run() {
  local out rc=0 n_added n_already n_want=0 a mark added_ids already_ids
  for a in $4; do n_want=$((n_want + 1)); done
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
      -v tenant="$1" -v channel="$2" -v box="$3" -v agents="$4" -v allowdef="${5:-0}" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT (:'channel' IN ('tasks', 'issues', 'general')
        OR (:'channel' IN ('lobby', 'alerts', 'feedback') AND :'allowdef' <> '1'))::int AS ispub \gset
\if :ispub
ROLLBACK;
SELECT format('refuse-public | %s', :'channel');
\quit 1
\endif
SELECT (:'channel' IN ('lobby', 'alerts', 'feedback'))::int AS isdef \gset
\if :isdef
INSERT INTO channels (tenant_id, channel_id, name, created_by, members_open_invite)
VALUES (:'tenant', :'channel', :'channel', 'hub', false)
ON CONFLICT (tenant_id, channel_id) DO NOTHING;
\endif
SELECT EXISTS (
         SELECT 1 FROM channels
          WHERE tenant_id = :'tenant' AND channel_id = :'channel' AND deleted_at IS NULL
       )::int AS chok \gset
\if :chok
\else
ROLLBACK;
SELECT format('refuse-channel | %s', :'channel');
\quit 1
\endif
SELECT coalesce(string_agg(s.a, ' ' ORDER BY s.a), '') AS missing
  FROM (
         SELECT DISTINCT btrim(x) AS a
           FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
          WHERE btrim(x) <> ''
            AND NOT EXISTS (
              SELECT 1 FROM roster r
               WHERE r.tenant_id = :'tenant' AND r.box_id = :'box' AND r.agent_id = btrim(x)
            )
       ) s \gset
SELECT (:'missing' <> '')::int AS anymissing \gset
\if :anymissing
ROLLBACK;
SELECT format('refuse-not-a-member | %s', :'missing');
\quit 1
\endif
SELECT count(*)::int AS nwant FROM (
         SELECT DISTINCT btrim(x) AS a
           FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
          WHERE btrim(x) <> ''
       ) w \gset
SELECT coalesce(string_agg(s.a, ' ' ORDER BY s.a), '') AS had
  FROM (
         SELECT DISTINCT btrim(x) AS a
           FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
          WHERE btrim(x) <> ''
            AND EXISTS (
              SELECT 1 FROM channel_subscriptions c
               WHERE c.tenant_id = :'tenant' AND c.channel_id = :'channel'
                 AND c.box_id = :'box' AND c.agent_id = btrim(x)
                 AND c.origin <> 'removed'
            )
       ) s \gset
SELECT count(*)::int AS nalready FROM (
         SELECT btrim(x) AS a
           FROM unnest(string_to_array(:'had', ' ')) AS t(x)
          WHERE btrim(x) <> ''
       ) h \gset
UPDATE channel_subscriptions AS c
   SET origin = 'invite'
 WHERE c.tenant_id = :'tenant' AND c.channel_id = :'channel' AND c.box_id = :'box'
   AND c.origin = 'removed'
   AND c.agent_id IN (
         SELECT DISTINCT btrim(x)
           FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
          WHERE btrim(x) <> ''
       );
SELECT :ROW_COUNT AS nrevived \gset
INSERT INTO channel_subscriptions (tenant_id, channel_id, agent_id, box_id, origin)
SELECT :'tenant', :'channel', w.a, :'box', 'invite'
  FROM (
         SELECT DISTINCT btrim(x) AS a
           FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
          WHERE btrim(x) <> ''
       ) w
ON CONFLICT (tenant_id, channel_id, agent_id, box_id) DO NOTHING;
SELECT :ROW_COUNT AS nadded \gset
SELECT (:nadded::int + :nalready::int + :nrevived::int = :nwant::int)::int AS ok \gset
\if :ok
SELECT format('added | %s', btrim(x))
  FROM unnest(string_to_array(:'agents', ' ')) AS t(x)
 WHERE btrim(x) <> ''
   AND NOT (btrim(x) = ANY (string_to_array(:'had', ' ')))
 GROUP BY btrim(x)
 ORDER BY 1;
SELECT format('already | %s', btrim(x))
  FROM unnest(string_to_array(:'had', ' ')) AS t(x)
 WHERE btrim(x) <> ''
 ORDER BY 1;
COMMIT;
\else
ROLLBACK;
SELECT 'refuse-count';
\quit 1
\endif
SQL
)" || rc=$?
  # psql 18 treats "\quit 1" as \quit and exits 0 (the code is ignored), so a
  # refusal is recognised from the line the script printed, not from rc.
  if grep -q '^refuse-not-a-member | ' <<<"$out"; then
    mark="$(grep '^refuse-not-a-member | ' <<<"$out" | head -n 1)"
    do_log "FATAL not_a_member: ${mark##*| } is not announced on $3 in $1"
    return 1
  elif grep -q '^refuse-channel | ' <<<"$out"; then
    mark="$(grep '^refuse-channel | ' <<<"$out" | head -n 1)"
    do_log "FATAL no channel ${mark##*| } in $1"
    return 1
  elif grep -q '^refuse-public | ' <<<"$out"; then
    mark="$(grep '^refuse-public | ' <<<"$out" | head -n 1)"
    do_log "FATAL #${mark##*| } is a default channel: an agent seat is not stored"
    return 1
  elif grep -q '^refuse-count$' <<<"$out"; then
    do_log "FATAL agent add of $4 to #$2 on $3 in $1 changed an unexpected number of rows; rolled back"
    return 1
  elif (( rc != 0 )); then
    do_log "FATAL agent add of $4 to #$2 on $3 in $1 failed: $out"
    return 1
  fi
  n_added="$(grep -c '^added | ' <<<"$out" || true)"
  n_already="$(grep -c '^already | ' <<<"$out" || true)"
  if (( n_added + n_already != n_want )); then
    do_log "FATAL agent add of $4 to #$2 on $3 in $1 returned $n_added added and $n_already already, want $n_want: $out"
    return 1
  fi
  if (( n_added > 0 )); then
    added_ids="$(grep '^added | ' <<<"$out" | sed 's/^added | //' | paste -sd ' ' -)"
    do_log "OK added $added_ids on $3 to #$2 in $1 ($GCP_ACCOUNT)"
  fi
  if (( n_already == 1 )); then
    already_ids="$(grep '^already | ' <<<"$out" | sed 's/^already | //' | paste -sd ' ' -)"
    do_log "OK $already_ids is already a member of #$2 on $3 in $1 ($GCP_ACCOUNT)"
  elif (( n_already > 1 )); then
    already_ids="$(grep '^already | ' <<<"$out" | sed 's/^already | //' | paste -sd ' ' -)"
    do_log "OK $already_ids are already members of #$2 on $3 in $1 ($GCP_ACCOUNT)"
  fi
}
