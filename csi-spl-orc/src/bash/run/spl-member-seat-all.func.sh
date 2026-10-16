#!/bin/bash
#------------------------------------------------------------------------------
# @description Seat one person in every listed workspace AND in every live
# @description channel of each (SPL-2126, owner HUM-10: "all of them should see
# @description all of the channels"). Per tenant of TENANT_IDS: a read-only
# @description lookup (the human behind HUMAN_ID or EMAIL, its membership and
# @description role, the live channels that hold membership rows), then the
# @description named actions do the writes: do_spl_tenant_member_add for a
# @description non-member, do_spl_tenant_member_role when the role differs
# @description from MEMBER_ROLE, do_spl_channel_member_add per channel. Default
# @description channels (lobby, alerts, feedback, tasks) and #issues are shown
# @description to every member and are skipped. Idempotent: a seated person is
# @description reported, nothing changes.
# @description An EMAIL with no human yet (the invitee has not signed in) is
# @description "pending": exit 3, nothing written. WATCH=1 re-runs every
# @description WATCH_INTERVAL seconds until the person is seated or WATCH_UNTIL
# @description passes: the on-sign-in seat of an open invite.
# @description DRY_RUN=1 (default): the lookup reads (read-only transaction),
# @description each write is the named action's own DRY_RUN plan.
# @param ENV - required: dev or prd
# @param TENANT_IDS - required: space-separated tenant slugs, e.g. 'acme demo'
# @param HUMAN_ID - a human id, e.g. HUM-4. Set this or EMAIL, not both.
# @param EMAIL - the invitee's email (lower-cased), resolved through
# @param   human_identities to exactly one human; none yet = pending (exit 3)
# @param MEMBER_ROLE - required: the role id in every tenant of TENANT_IDS
# @param ORDERED_BY - required when DRY_RUN=0: the HUM-* who ordered the seat
# @param ORDERED_VIA (optional) - the agent or channel that carried the order
# @param WATCH (optional) - 1: repeat while pending; 0 (default): one pass
# @param WATCH_INTERVAL (optional) - seconds between passes, default 300
# @param WATCH_UNTIL (optional) - a date(1) time to give up, default +7 days
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_IDS='acme demo' HUMAN_ID=HUM-4 MEMBER_ROLE=developer ORDERED_BY=HUM-10 DRY_RUN=0 ./run -a do_spl_member_seat_all
# @example ENV=prd TENANT_IDS='acme demo' EMAIL=person@example.com MEMBER_ROLE=admin ORDERED_BY=HUM-10 WATCH=1 DRY_RUN=0 ./run -a do_spl_member_seat_all
#------------------------------------------------------------------------------
do_spl_member_seat_all() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenants="${TENANT_IDS:-}" human="${HUMAN_ID:-}" email="${EMAIL:-}" role="${MEMBER_ROLE:-}" t drc=0
  [[ -n "${tenants// /}" ]] || { do_log "FATAL TENANT_IDS is required: space-separated tenant slugs"; return 1; }
  for t in $tenants; do spl_require_tenant_slug "$t" || return 1; done
  if [[ -n "$human" && -n "$email" ]] || [[ -z "$human" && -z "$email" ]]; then
    do_log "FATAL set exactly one of HUMAN_ID or EMAIL"
    return 1
  fi
  if [[ -n "$human" ]]; then
    [[ "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4, got: '$human'"; return 1; }
  else
    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL EMAIL is not an email"; return 1; }
    email="${email,,}"
  fi
  [[ "$role" =~ ^[a-z_]{2,32}$ ]] || { do_log "FATAL MEMBER_ROLE must be a role id, got: '$role'"; return 1; }
  spl_dry_run || drc=$?
  (( drc == 2 )) && return 1
  if (( drc == 1 )) && [[ ! "${ORDERED_BY:-}" =~ ^HUM-[0-9]+$ ]]; then
    do_log "FATAL ORDERED_BY (a HUM-* id) is required when DRY_RUN=0"
    return 1
  fi
  [[ "${WATCH:-0}" == 1 ]] || { _spl_member_seat_all_pass "$tenants" "$human" "$email" "$role"; return; }
  _spl_member_seat_all_watch "$tenants" "$human" "$email" "$role"
}

# _spl_member_seat_all_watch <tenants> <human> <email> <role>: one pass every
# WATCH_INTERVAL seconds while the person is pending (exit 3), until WATCH_UNTIL.
_spl_member_seat_all_watch() {
  local every="${WATCH_INTERVAL:-300}" until rc
  [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 )) || { do_log "FATAL WATCH_INTERVAL must be seconds >= 1, got: '$every'"; return 1; }
  until="$(date -d "${WATCH_UNTIL:-+7 days}" +%s 2>/dev/null)" || { do_log "FATAL WATCH_UNTIL is not a date(1) time: '${WATCH_UNTIL:-}'"; return 1; }
  while :; do
    rc=0; _spl_member_seat_all_pass "$@" || rc=$?
    (( rc == 3 )) || return $rc
    (( $(date +%s) + every <= until )) || { do_log "WARN still pending at WATCH_UNTIL: gave up, nothing seated"; return 3; }
    sleep "$every"
  done
}

# _spl_member_seat_all_pass <tenants> <human> <email> <role>: look every tenant
# up (one proxy), then seat through the named actions. 3 = not signed in yet.
_spl_member_seat_all_pass() {
  local tenants="$1" human="$2" email="$3" role="$4" plan rc=0 t hid cur ch
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  plan="$(spl_via_proxy _spl_member_seat_all_lookup "$tenants" "$human" "$email")" || return 1
  hid="$(spl_psql_mark "$plan" human)" || { do_log "FATAL the lookup printed no human line"; return 1; }
  case "$hid" in
    none) do_log "INFO pending: no human signed in with that email yet; nothing seated in $tenants"; return 3 ;;
    many:*) do_log "FATAL the email matches ${hid#many:} humans in human_identities; want exactly one"; return 1 ;;
    missing) do_log "FATAL human $human is not in humans"; return 1 ;;
  esac
  for t in $tenants; do
    cur="$(grep -m 1 "^member | $t | " <<<"$plan")"; cur="${cur##*| }"
    if [[ -z "$cur" ]]; then
      do_log "FATAL the lookup printed no member line for $t"; rc=1; continue
    elif [[ "$cur" == - ]]; then
      TENANT_ID="$t" HUMAN_ID="$hid" EMAIL='' MEMBER_ROLE="$role" CREATE_HUMAN=0 do_spl_tenant_member_add || { rc=1; continue; }
    elif [[ "$cur" != "$role" ]]; then
      TENANT_ID="$t" HUMAN_ID="$hid" MEMBER_ROLE="$role" FROM_ROLE="$cur" do_spl_tenant_member_role || { rc=1; continue; }
    else
      do_log "OK $hid is already a $role of $t"
    fi
    while IFS= read -r ch; do
      [[ -n "$ch" ]] || continue
      TENANT_ID="$t" CHANNEL="$ch" HUMAN_ID="$hid" EMAIL='' do_spl_channel_member_add || rc=1
    done < <(grep "^chan | $t | " <<<"$plan" | sed 's/.*| //')
  done
  (( rc == 0 )) && do_log "OK $hid seated in $tenants and every channel there (role $role)"
  return $rc
}

# _spl_member_seat_all_lookup <tenants> <human> <email>: one read-only
# transaction per tenant; prints "human | <id|none|many:N|missing>", then per
# tenant "member | <t> | <role|->" and one "chan | <t> | <id>" per channel.
_spl_member_seat_all_lookup() {
  local t
  for t in $1; do
    _spl_member_seat_all_sql |
      spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
        -v tenant="$t" -v human="$2" -v email="$3" || return 1
  done
}

_spl_member_seat_all_sql() {
  cat <<'SQL'
BEGIN READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT CASE
         WHEN :'human' <> '' THEN
           CASE WHEN EXISTS (SELECT 1 FROM humans WHERE human_id = :'human') THEN :'human' ELSE 'missing' END
         ELSE (SELECT CASE count(DISTINCT human_id) WHEN 0 THEN 'none' WHEN 1 THEN min(human_id)
                      ELSE 'many:' || count(DISTINCT human_id) END
                 FROM human_identities WHERE email = :'email')
       END AS hid \gset
SELECT format('human | %s', :'hid');
SELECT format('member | %s | %s', :'tenant',
         coalesce((SELECT role FROM tenant_memberships
                    WHERE tenant_id = :'tenant' AND human_id = :'hid'), '-'));
SELECT format('chan | %s | %s', :'tenant', channel_id) FROM channels
 WHERE tenant_id = :'tenant' AND deleted_at IS NULL
   AND channel_id NOT IN ('lobby', 'alerts', 'feedback', 'tasks', 'issues', 'general')
 ORDER BY channel_id;
COMMIT;
SQL
}
