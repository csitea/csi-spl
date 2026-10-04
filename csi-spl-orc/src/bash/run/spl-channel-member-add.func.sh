#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat one human in a channel. INSERT a channel_humans row with
# @description added_by='operator' — the row handleAddChannelMember writes —
# @description through the Cloud SQL proxy, as the env's project service
# @description account. The human must already be a member of the tenant
# @description (else FATAL not_a_member). A default channel (lobby, alerts,
# @description feedback, tasks; general is lobby) and the reserved issues
# @description channel are refused: those have no membership rows. The channel
# @description must exist and not be deleted, or the transaction rolls back.
# @description ON CONFLICT (tenant_id, channel_id, human_id) DO NOTHING: an
# @description existing member is reported and nothing else changes. EMAIL is
# @description resolved through human_identities to exactly one human, or the
# @description transaction is rolled back. Values travel as psql variables
# @description (:'var'), never spliced into the SQL. The statement sets
# @description app.tenant_id for the transaction (rdb 0014). This is the
# @description OPERATOR path: outside the hub's mayInviteChannel check.
# @description DRY_RUN=1 (default): print the change, call no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param CHANNEL - required: the channel id
# @param HUMAN_ID - a human id, e.g. HUM-4. Set this or EMAIL, not both.
# @param EMAIL - the human's email. Resolved through human_identities to
# @param   exactly one human_id, or the run refuses. Set this or HUMAN_ID,
# @param   not both. Stored and compared lower-cased.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 CHANNEL=release-notes EMAIL=person@example.com DRY_RUN=0 ./run -a do_spl_channel_member_add
#------------------------------------------------------------------------------
do_spl_channel_member_add() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" human="${HUMAN_ID:-}" email="${EMAIL:-}" ch="${CHANNEL:-}" dry=1 raw
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$ch" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL CHANNEL must be a channel id, got: '$ch'"; return 1; }
  raw="$ch"
  [[ "$ch" == general ]] && ch=lobby
  case "$ch" in
    issues)
      do_log "FATAL #issues is reserved and is not a channel a member is added to"
      return 1 ;;
    lobby|alerts|feedback|tasks)
      if [[ "$raw" == general ]]; then
        do_log "FATAL #general is #lobby, a default channel (lobby, alerts, feedback, tasks): a membership row is not stored"
      else
        do_log "FATAL #$ch is a default channel (lobby, alerts, feedback, tasks): a membership row is not stored"
      fi
      return 1 ;;
  esac
  if [[ -n "$human" && -n "$email" ]] || [[ -z "$human" && -z "$email" ]]; then
    do_log "FATAL set exactly one of HUMAN_ID or EMAIL"
    return 1
  fi
  if [[ -n "$human" ]]; then
    [[ "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  else
    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL EMAIL is not an email: '$email'"; return 1; }
    email="${email,,}"
  fi
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    if [[ -n "$email" ]]; then
      do_log "OK DRY_RUN would add $email to #$ch in $tenant (added_by=operator) on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    else
      do_log "OK DRY_RUN would add $human to #$ch in $tenant (added_by=operator) on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    fi
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_channel_member_add_run "$tenant" "$human" "$email" "$ch"
}

_spl_channel_member_add_run() {
  local out rc=0 n_added n_already line who="$2" mark
  [[ -n "$who" ]] || who="$3"
  out="$(_spl_channel_member_add_sql |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
      -v tenant="$1" -v human="$2" -v email="$3" -v channel="$4")" || rc=$?
  # psql 18 treats "\quit 1" as \quit and exits 0 (the code is ignored), so a
  # refusal is recognised from the line the script printed, not from rc.
  if mark="$(spl_psql_mark "$out" refuse-human)"; then
    do_log "FATAL email $3 matches $mark human(s) in human_identities; want exactly one"
    return 1
  elif mark="$(spl_psql_mark "$out" refuse-missing-human)"; then
    do_log "FATAL human $mark is not in humans"
    return 1
  elif mark="$(spl_psql_mark "$out" refuse-not-a-member)"; then
    do_log "FATAL not_a_member: $mark is not a member of $1"
    return 1
  elif mark="$(spl_psql_mark "$out" refuse-channel)"; then
    do_log "FATAL no channel $mark in $1"
    return 1
  elif mark="$(spl_psql_mark "$out" refuse-public)"; then
    do_log "FATAL #$mark is a default channel: a membership row is not stored"
    return 1
  elif grep -q '^refuse-count$' <<<"$out"; then
    do_log "FATAL member add of $who to #$4 in $1 changed an unexpected number of rows; rolled back"
    return 1
  elif (( rc != 0 )); then
    do_log "FATAL member add of $who to #$4 in $1 failed: $out"
    return 1
  fi
  n_added="$(grep -c '^added | ' <<<"$out" || true)"
  n_already="$(grep -c '^already | ' <<<"$out" || true)"
  if (( n_added + n_already != 1 )); then
    do_log "FATAL member add of $who to #$4 in $1 returned no single membership result: $out"
    return 1
  fi
  if (( n_added == 1 )); then
    line="$(grep '^added | ' <<<"$out" | sed -n 1p)"
    do_log "OK added $who to #$4 in $1 ($GCP_ACCOUNT): $line"
  else
    line="$(grep '^already | ' <<<"$out" | sed -n 1p)"
    do_log "OK ${line#already | } is already a member of #$4 in $1 ($GCP_ACCOUNT)"
  fi
}

# _spl_channel_member_add_sql: the one-transaction add script - refuse a public or
# missing channel, an email that is not exactly one human, a human not in the
# tenant; else upsert the membership and print "added | ..." / "already | ...".
_spl_channel_member_add_sql() {
  cat <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
SELECT (:'channel' IN ('lobby', 'alerts', 'feedback', 'tasks', 'issues', 'general'))::int AS ispub \gset
\if :ispub
ROLLBACK;
SELECT format('refuse-public | %s', :'channel');
\quit 1
\endif
SELECT CASE
         WHEN :'human' <> '' THEN 1
         ELSE (SELECT count(DISTINCT human_id)::int FROM human_identities WHERE email = :'email')
       END AS nhum \gset
SELECT (:nhum = 1)::int AS onehuman \gset
\if :onehuman
\else
ROLLBACK;
SELECT format('refuse-human | %s', :nhum);
\quit 1
\endif
SELECT CASE
         WHEN :'human' <> '' THEN :'human'
         ELSE (SELECT min(human_id) FROM human_identities WHERE email = :'email')
       END AS hid \gset
SELECT EXISTS (SELECT 1 FROM humans WHERE human_id = :'hid')::int AS humok \gset
\if :humok
\else
ROLLBACK;
SELECT format('refuse-missing-human | %s', :'hid');
\quit 1
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
SELECT EXISTS (
         SELECT 1 FROM tenant_memberships
          WHERE tenant_id = :'tenant' AND human_id = :'hid'
       )::int AS ismem \gset
\if :ismem
\else
ROLLBACK;
SELECT format('refuse-not-a-member | %s', :'hid');
\quit 1
\endif
INSERT INTO channel_humans (tenant_id, channel_id, human_id, added_by)
VALUES (:'tenant', :'channel', :'hid', 'operator')
ON CONFLICT (tenant_id, channel_id, human_id) DO NOTHING;
SELECT (:ROW_COUNT = 1)::int AS inserted \gset
\if :inserted
SELECT format('added | %s | %s | %s | operator', :'tenant', :'channel', :'hid');
COMMIT;
\else
SELECT EXISTS (
         SELECT 1 FROM channel_humans
          WHERE tenant_id = :'tenant' AND channel_id = :'channel' AND human_id = :'hid'
       )::int AS present \gset
\if :present
SELECT format('already | %s', :'hid');
COMMIT;
\else
ROLLBACK;
SELECT 'refuse-count';
\quit 1
\endif
\endif
SQL
}
