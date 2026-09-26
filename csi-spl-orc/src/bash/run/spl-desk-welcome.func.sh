#!/bin/bash
#------------------------------------------------------------------------------
# @description The desk bots welcome a person admitted to a tenant for the
# @description first time (SPL-961): up to WELCOME_CAP seated, live bots of
# @description that tenant each post ONE cheerful welcome naming the person
# @description into #lobby (do_spl_desk_post), in the person's preferred_locale
# @description or else cnf env.i18n.default_locale, each at most 33 words and
# @description each a different variant (scripts/desk-welcome-text.py).
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
# @description Bots rotate round-robin over the tenant's live seats. Run by
# @description desk-reconcile-cron.sh every tick. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID (optional) - space-separated tenants; default every tenant
# @param   with a pinned desk on DESK_BOX in this env's state dir
# @param DESK_BOX (optional) - default box-desk
# @param WELCOME_CAP (optional) - bots per person, 1..10, default 3
# @param WELCOME_MAX_AGE_H (optional) - oldest admit greeted, hours, default 24
# @param WELCOME_TRIES (optional) - refused posts per bot before giving up, default 3
# @param WELCOME_INCLUDE_TEST (optional) - 1 greets test/proof accounts too (live proofs), default 0
# @param WELCOME_PROXY_PORT (optional) - local proxy port, default 55487 dev / 55488 prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_desk_welcome
# @example ENV=prd TENANT_ID=e2e WELCOME_CAP=1 ./run -a do_spl_desk_welcome
#------------------------------------------------------------------------------
do_spl_desk_welcome() {
  do_require_bin python3 yq flock || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local box="${DESK_BOX:-box-desk}" cap="${WELCOME_CAP:-3}" age="${WELCOME_MAX_AGE_H:-24}" tries="${WELCOME_TRIES:-3}"
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ "$cap" =~ ^([1-9]|10)$ ]] || { do_log "FATAL WELCOME_CAP must be 1..10, got: '$cap'"; return 1; }
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

  local line tenant human at name locale base D greeted=0 failed=0
  local -a live=() plan=()
  mapfile -t live < <(spl_desk_live_agents)
  # \x1f, not a tab: a tab is IFS whitespace, so an empty locale would
  # collapse and shift the fields after it.
  while IFS=$'\x1f' read -r tenant human at name locale istest; do
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
    mkdir -p "$D" || return 1
    if [[ ! -s "$D/plan" ]]; then
      spl_desk_welcome_plan "$L/$tenant" "$SPL_STATE_DIR/desk/$tenant/$box/spool" "$cap" "${live[@]}" >"$D/plan.tmp" &&
        mv -f "$D/plan.tmp" "$D/plan"
      if [[ ! -s "$D/plan" ]]; then
        rm -f "$D/plan" "$D/plan.tmp"
        do_log "WARN $tenant: no live seated bot on $box to welcome $human yet; the next tick tries again"
        continue
      fi
    fi
    mapfile -t plan <"$D/plan"
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
    print("\x1f".join([r["tenant"], r["human"], str(r["at"]), name, r.get("locale") or "",
                     "1" if r.get("test") else "0"]))
')
  do_log "OK welcome run over ${tenants[*]} in $ENV: $greeted greeting(s) posted, $failed refused"
  (( failed == 0 ))
}

# spl_desk_welcome_plan <tenant ledger dir> <desk spool dir> <cap> <live...>:
# the bots that greet one person, one per line - the tenant's seated agents
# that have a live window, sorted, taken round-robin from the tenant's rr
# counter, which moves on by what was taken so the next person meets others.
spl_desk_welcome_plan() {
  local ld="$1" spool="$2" cap="$3"; shift 3
  local -a seated=()
  local a live=" $* "
  for a in "$spool"/*/; do
    a="$(basename "$a")"
    [[ "$a" =~ ^[A-Z]{2,4}-[0-9]+$ && "${a%%-*}" != HUM && "${a%%-*}" != BOX ]] || continue
    [[ "$live" == *" $a "* ]] && seated+=("$a")
  done
  (( ${#seated[@]} )) || return 0
  mapfile -t seated < <(printf '%s\n' "${seated[@]}" | sort)
  local n=${#seated[@]} rr i
  rr="$(cat "$ld/rr" 2>/dev/null)"; [[ "$rr" =~ ^[0-9]+$ ]] || rr=0
  (( cap > n )) && cap=$n
  for ((i = 0; i < cap; i++)); do printf '%s\n' "${seated[$(((rr + i) % n))]}"; done
  printf '%s\n' "$(((rr + cap) % n))" >"$ld/rr"
}

# spl_desk_welcome_post <tenant> <box> <bot> <body>: one #lobby post as <bot>.
spl_desk_welcome_post() {
  ( TENANT_ID="$1" DESK_BOX="$2" DESK_AGENT="$3" DESK_CHANNEL=lobby DESK_KIND=note DESK_BODY="$4" DRY_RUN=0 \
      DESK_TYPED_BY="" DESK_FILES="" do_spl_desk_post )
}

# spl_desk_welcome_admits "<tenant ...>" <hours>: one JSON line per membership
# of those tenants younger than <hours> whose human is not disabled -
# {tenant, human, at (epoch s), name, locale, test}. The name is the display
# name, else the email's local part; the email itself never leaves this query.
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
                    OR coalesce(h.display_name, '') ~* '(e2e|proof)'))
  FROM tenant_memberships m
  JOIN humans h USING (human_id)
 WHERE m.tenant_id = ANY (string_to_array(:'tenants', ' '))
   AND m.created_at > now() - make_interval(hours => :'hours'::int)
   AND h.disabled_at IS NULL
 ORDER BY m.created_at, m.tenant_id, m.human_id;
ROLLBACK;
SQL
}
