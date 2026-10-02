#!/bin/bash
#------------------------------------------------------------------------------
# @description The desk bots welcome a person admitted to a tenant for the
# @description first time (SPL-961): the tenant's ONE configured greeter posts
# @description ONE cheerful welcome naming the person into #lobby
# @description (do_spl_desk_post), in the person's preferred_locale or else cnf
# @description env.i18n.default_locale, at most 33 words
# @description (scripts/desk-welcome-text.py). The greeter is the agent id in
# @description <state>/desk/<tenant>/<box>/greeter (do_spl_desk_set_greeter);
# @description a tenant with no greeter greets nobody (CLE-77896: three
# @description unrelated lanes once each welcomed one new member within 2 s),
# @description and a greeter that is not seated + live waits for a tick.
# @description Exactly once per tenant + human, across restarts and retries:
# @description a ledger under <state>/welcome/<tenant>/<human>/ holds the bot
# @description plan, a claim file written BEFORE each post and a posted file
# @description (the msg_id) after it. A claim with no posted file means a run
# @description died mid-post, so that bot is skipped, never repeated: a
# @description missing greeting is recoverable, a doubled one is not. A post
# @description the hub refused releases its claim and is retried on the next
# @description tick, WELCOME_TRIES times at most.
# @description Admits are tenant_memberships rows (invite acceptance,
# @description bootstrap, operator member_add) younger than WELCOME_MAX_AGE_H
# @description and newer than the tenant's baseline: the first run for a
# @description tenant writes its baseline, so the members it already has are
# @description never greeted. Read through the Cloud SQL proxy as the env's
# @description project service account, in a READ ONLY transaction.
# @description A test or proof account is never greeted (an @example.com
# @description address, or e2e / proof in the address or the display name)
# @description unless WELCOME_INCLUDE_TEST=1, which is for a live proof only.
# @description Run by desk-reconcile-cron.sh every tick. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - space-separated tenants; default every tenant
# @param   with a pinned desk on DESK_BOX in this env's state dir
# @param DESK_BOX (optional) - default box-desk
# @param WELCOME_MAX_AGE_H (optional) - oldest admit greeted, hours, default 24
# @param WELCOME_TRIES (optional) - refused posts per bot before giving up, default 3
# @param WELCOME_INCLUDE_TEST (optional) - 1 greets test/proof accounts too (live proofs), default 0
# @param WELCOME_PROXY_PORT (optional) - local proxy port, default 55487 dev / 55488 prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_desk_welcome
# @example ENV=prd TENANT_ID=e2e ./run -a do_spl_desk_welcome
#------------------------------------------------------------------------------
do_spl_desk_welcome() {
  do_require_bin python3 yq flock || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local box="${DESK_BOX:-$(spl_desk_box_default)}" age="${WELCOME_MAX_AGE_H:-24}" tries="${WELCOME_TRIES:-3}"
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ "$age" =~ ^[1-9][0-9]{0,3}$ ]] || { do_log "FATAL WELCOME_MAX_AGE_H must be 1..9999 hours, got: '$age'"; return 1; }
  [[ "$tries" =~ ^[1-9]$ ]] || { do_log "FATAL WELCOME_TRIES must be 1..9, got: '$tries'"; return 1; }
  local withtest="${WELCOME_INCLUDE_TEST:-0}"
  [[ "$withtest" == 0 || "$withtest" == 1 ]] || { do_log "FATAL WELCOME_INCLUDE_TEST must be 0 or 1, got: '$withtest'"; return 1; }

  local -a tenants=()
  local t
  if [[ -n "${TENANT_ID:-}" ]]; then
    read -r -a tenants <<<"$TENANT_ID"
  else
    for t in "$SPL_STATE_DIR"/desk/*/"$box"/pinned; do
      [[ -s "$t" ]] && tenants+=("$(basename "$(dirname "$(dirname "$t")")")")
    done
  fi
  for t in "${tenants[@]}"; do
    [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID entry '$t' is not a tenant slug"; return 1; }
  done
  if [[ ${#tenants[@]} -eq 0 ]]; then
    do_log "OK no tenant has a desk on $box in $ENV: nobody to welcome anyone"
    return 0
  fi

  local L="$SPL_STATE_DIR/welcome" deflocale
  deflocale="$(yq -r '.env.i18n.default_locale // "en"' "$SPL_CNF" 2>/dev/null)"
  [[ "$deflocale" =~ ^[a-z]{2}$ ]] || deflocale=en

  local admits rc=0
  admits="$(spl_desk_welcome_admits "${tenants[*]}" "$age")" || rc=$?
  (( rc == 0 )) || { do_log "FATAL cannot read the new admits of ${tenants[*]} in $ENV"; return 1; }

  if (( dry )); then
    local n
    n="$(grep -c . <<<"$admits" || true)"
    do_log "INFO DRY_RUN $n admit(s) younger than ${age}h in ${tenants[*]}; the ledger decides which are new"
    [[ -n "$admits" ]] && printf '%s\n' "$admits"
    do_log "OK DRY_RUN nothing was posted and no ledger was written. Re-run with DRY_RUN=0."
    return 0
  fi

  mkdir -p "$L" || { do_log "FATAL cannot create $L"; return 1; }
  chmod 700 "$L" 2>/dev/null || true
  # One welcome run at a time per env: the cron tick and a human running this
  # by hand would otherwise both plan the same person.
  exec 7>"$L/.lock" || { do_log "FATAL cannot open $L/.lock"; return 1; }
  flock -n 7 || { do_log "OK another welcome run holds $L/.lock; this tick leaves it to that one"; return 0; }

  local now
  now="$(date +%s)"
  for t in "${tenants[@]}"; do
    mkdir -p "$L/$t" || return 1
    if [[ ! -s "$L/$t/baseline" ]]; then
      printf '%s\n' "$now" >"$L/$t/baseline"
      do_log "INFO $t: first welcome run, baseline $(date -u -d "@$now" +%FT%TZ) - the members it has now are never greeted"
    fi
  done

  local tenant human at name locale base D greeted=0 failed=0
  local invon ordname ordvia prov greeter
  local -a live=() plan=()
  mapfile -t live < <(spl_desk_live_agents)
  # \x1f, not a tab: a tab is IFS whitespace, so an empty locale would
  # collapse and shift the fields after it.
  while IFS=$'\x1f' read -r tenant human at name locale istest invon ordname ordvia; do
    [[ -n "$tenant" ]] || continue
    [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$human" =~ ^HUM-[0-9]+$ && "$at" =~ ^[0-9]+$ ]] ||
      { do_log "WARN skipping a malformed admit row: $tenant $human $at"; continue; }
    base="$(cat "$L/$tenant/baseline" 2>/dev/null)"
    [[ "$base" =~ ^[0-9]+$ ]] || continue
    (( at > base )) || continue
    D="$L/$tenant/$human"
    [[ -e "$D/done" ]] && continue
    if [[ "$istest" == 1 && "$withtest" != 1 ]]; then
      do_log "INFO $tenant: $human is a test/proof account; not greeted (WELCOME_INCLUDE_TEST=1 for a live proof)"
      continue
    fi
    if [[ ! -s "$D/plan" ]]; then
      greeter="$(spl_desk_greeter "$tenant" "$box")"
      if [[ -z "$greeter" ]]; then
        # Decided, not deferred: configuring a greeter later never greets
        # the people admitted before it.
        mkdir -p "$D" && printf '%s no-greeter\n' "$(date -u +%FT%TZ)" >"$D/done"
        do_log "INFO $tenant: no greeter configured on $box (do_spl_desk_set_greeter); nobody greets $human"
        continue
      fi
      mkdir -p "$D" || return 1
      spl_desk_welcome_plan "$SPL_STATE_DIR/desk/$tenant/$box/spool" "$greeter" "${live[@]}" >"$D/plan.tmp" &&
        mv -f "$D/plan.tmp" "$D/plan"
      if [[ ! -s "$D/plan" ]]; then
        rm -f "$D/plan" "$D/plan.tmp"
        do_log "WARN $tenant: greeter $greeter is not seated and live on $box to welcome $human yet; the next tick tries again"
        continue
      fi
    fi
    mapfile -t plan <"$D/plan"
    # CLE-77778: the provenance footer answers "who invited this person, and
    # when" right in #lobby. Only slot 0 carries it (a ledger from before
    # CLE-77896 may still plan three bots); it sits OUTSIDE the cheerful
    # 33-word body (a factual line, not counted against desk-welcome-text.py's
    # cap). Blank when the member did not come through an invite.
    prov=""
    if [[ -n "$invon" || -n "$ordname" ]]; then
      prov="invited"
      [[ -n "$invon" ]] && prov+=" $invon"
      [[ -n "$ordname" ]] && prov+=" by $ordname"
      [[ -n "$ordvia" ]] && prov+=" (via $ordvia)"
    fi
    local i bot body out mid n all=1
    for i in "${!plan[@]}"; do
      bot="${plan[$i]}"
      [[ -e "$D/$bot.posted" || -e "$D/$bot.gaveup" ]] && continue
      if [[ -e "$D/$bot.claim" ]]; then
        # A run died between the claim and the posted mark: the post may be
        # on the hub already. Never risk a second copy.
        do_log "WARN $tenant/$human: $bot holds a claim with no posted mark (a run died mid-post); not posting again"
        mv -f "$D/$bot.claim" "$D/$bot.gaveup"
        continue
      fi
      body="$(python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/desk-welcome-text.py" \
        --locale "$locale" --default-locale "$deflocale" --slot "$i" --seed "$tenant/$human" --name "$name")" ||
        { do_log "FAIL $tenant/$human: no welcome text"; all=0; failed=$((failed + 1)); continue; }
      [[ $i -eq 0 && -n "$prov" ]] && body+=$'\n\n'"$prov"
      date -u +%FT%TZ >"$D/$bot.claim"
      if out="$(spl_desk_welcome_post "$tenant" "$box" "$bot" "$body" 2>&1)"; then
        mid="$(grep -o '"msg_id": *"[0-9a-f-]*"' <<<"$out" | head -n 1 | grep -o '[0-9a-f-]\{36\}')"
        printf '%s\n' "${mid:-sent}" >"$D/$bot.posted"
        rm -f "$D/$bot.claim"
        greeted=$((greeted + 1))
        do_log "OK $bot welcomed $human in #lobby of $tenant (${locale:-$deflocale}) msg_id=${mid:-?}"
      else
        rm -f "$D/$bot.claim"
        n=$(( $(cat "$D/$bot.tries" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$n" >"$D/$bot.tries"
        if (( n >= tries )); then
          : >"$D/$bot.gaveup"
          do_log "FAIL $bot could not welcome $human in $tenant after $n tries; giving up on this bot: $(tail -n 3 <<<"$out")"
        else
          all=0
          do_log "WARN $bot could not welcome $human in $tenant (try $n of $tries); the next tick retries: $(tail -n 3 <<<"$out")"
        fi
        failed=$((failed + 1))
      fi
    done
    (( all )) && date -u +%FT%TZ >"$D/done"
  done < <(printf '%s\n' "$admits" | python3 -c '
import json, sys
for l in sys.stdin:
    l = l.strip()
    if not l.startswith("{"):
        continue
    r = json.loads(l)
    name = " ".join(str(r.get("name") or "").split())
    ordname = " ".join(str(r.get("ordered_by_name") or "").split())
    ordvia = " ".join(str(r.get("ordered_via") or "").split())
    print("\x1f".join([r["tenant"], r["human"], str(r["at"]), name, r.get("locale") or "",
                     "1" if r.get("test") else "0",
                     str(r.get("invited_on") or ""), ordname, ordvia]))
')
  do_log "OK welcome run over ${tenants[*]} in $ENV: $greeted greeting(s) posted, $failed refused"
  (( failed == 0 ))
}

# spl_desk_greeter <tenant> <box>: the tenant's configured greeter (one agent
# id, do_spl_desk_set_greeter), or nothing when none is configured. A
# malformed file reads as none: a wrong greeter must never fall back to "any
# seated bot", which is the pile-on CLE-77896 removed.
spl_desk_greeter() {
  local g
  g="$(head -n 1 "$SPL_STATE_DIR/desk/$1/$2/greeter" 2>/dev/null | tr -d '[:space:]')"
  [[ "$g" =~ ^[A-Z]{2,4}-[0-9]+$ && "${g%%-*}" != HUM && "${g%%-*}" != BOX ]] && printf '%s\n' "$g"
  return 0
}

# spl_desk_welcome_plan <desk spool dir> <greeter> <live...>: the bot that
# greets one person - the greeter when it is seated on the desk and has a
# live window, else nothing (the person waits for a tick).
spl_desk_welcome_plan() {
  local spool="$1" g="$2"; shift 2
  local live=" $* "
  [[ -d "$spool/$g" && "$live" == *" $g "* ]] && printf '%s\n' "$g"
  return 0
}

# spl_desk_welcome_post <tenant> <box> <bot> <body>: one #lobby post as <bot>.
spl_desk_welcome_post() {
  ( TENANT_ID="$1" DESK_BOX="$2" DESK_AGENT="$3" DESK_CHANNEL=lobby DESK_KIND=note DESK_BODY="$4" DRY_RUN=0 \
      DESK_TYPED_BY="" DESK_FILES="" do_spl_desk_post )
}

# spl_desk_welcome_admits "<tenant ...>" <hours>: one JSON line per membership
# of those tenants younger than <hours> whose human is not disabled -
# {tenant, human, at (epoch s), name, locale, test, invited_on, ordered_by_name,
# ordered_via}. The name is the display name, else the email's local part; the
# email itself never leaves this query. The provenance (CLE-77778, rdb 0084) is
# the invite this member accepted (accepted_by = human_id): invited_on is its
# date, ordered_by_name the orderer's display name (else the HUM-* id), all ''
# when the member did not come through an invite.
# test: an @example.com address (every harness and proof account uses one), or
# e2e / proof in the address or the display name (the m3-e2e accounts).
spl_desk_welcome_admits() {
  SPL_PROXY_PORT="${WELCOME_PROXY_PORT:-$([[ "$ENV" == prd ]] && echo 55488 || echo 55487)}"
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_desk_welcome_admits_run "$1" "$2"
}

_spl_desk_welcome_admits_run() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -v tenants="$1" -v hours="$2" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT json_build_object(
         'tenant', m.tenant_id,
         'human',  m.human_id,
         'at',     floor(extract(epoch FROM m.created_at))::bigint,
         'name',   coalesce(nullif(btrim(h.display_name), ''),
                            nullif(split_part(split_part(coalesce(h.email, ''), '@', 1), '+', 1), ''),
                            ''),
         'locale', coalesce(h.preferred_locale, ''),
         'test',   (coalesce(h.email, '') LIKE '%@example.com'
                    OR coalesce(h.email, '') ~* '(e2e|proof)'
                    OR coalesce(h.display_name, '') ~* '(e2e|proof)'),
         'invited_on', coalesce(to_char(ti.created_at, 'YYYY-MM-DD'), ''),
         'ordered_by_name', coalesce(nullif(btrim(ho.display_name), ''), ti.ordered_by, ''),
         'ordered_via', coalesce(ti.ordered_via, ''))
  FROM tenant_memberships m
  JOIN humans h USING (human_id)
  LEFT JOIN tenant_invites ti ON ti.tenant_id = m.tenant_id AND ti.accepted_by = m.human_id
  LEFT JOIN humans ho ON ho.human_id = ti.ordered_by
 WHERE m.tenant_id = ANY (string_to_array(:'tenants', ' '))
   AND m.created_at > now() - make_interval(hours => :'hours'::int)
   AND h.disabled_at IS NULL
 ORDER BY m.created_at, m.tenant_id, m.human_id;
ROLLBACK;
SQL
}
