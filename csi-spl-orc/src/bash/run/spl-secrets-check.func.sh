#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only: does every Secret Manager slot of an env have an
# @description ENABLED version (spec 072 A30, research 09 K1)? The slots come
# @description from the RENDERED tfvars: 030 auth_secret_ids (every slot 030
# @description makes) and 040 dsn_secret_id / owner_dsn_secret_id. A slot is
# @description REQUIRED when the hub cannot start without it: 030
# @description secret_environment_variables injects it, or it is a 040 DSN.
# @description Every other slot is OPTIONAL (reported, never a failure), so a
# @description disabled IdP or payment rail is not a gap.
# @description One `gcloud secrets versions list` per slot; it NEVER calls
# @description `versions access`, so no value is ever read.
# @description Exit 1 when a required slot is empty or missing, each line
# @description naming the seed action that fills it (missing: the step to apply).
# @description Routed through do_spl_cloud_dispatch (spec 076 T006): the above
# @description is the gcp adapter; under SPOOL_CLOUD_PROVIDER=none it is
# @description do_secrets_check_none (the self-host .env and the state-volume
# @description session key, no gcloud at all).
# @param ENV - required (gcp): dev or prd
# @param SPOOL_CLOUD_PROVIDER (optional) - gcp (default) | none | aws, else the cnf env.cloud.provider
# @param SPOOL_SELF_HOST_DIR (optional, none) - the dir holding .env (default: this checkout)
# @param SPOOL_STATE_DIR (optional, none) - the hub state dir holding session.key (default /var/lib/spool/state)
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param SPL_TFVARS_DIR (optional) - default: the rendered <org>-<app>-cnf/<org>-<app>/<env>/tf
# @example ENV=dev ./run -a do_spl_secrets_check
# @example SPOOL_CLOUD_PROVIDER=none ./run -a do_spl_secrets_check
#------------------------------------------------------------------------------
do_spl_secrets_check() {
  do_spl_cloud_dispatch secrets check "$@"
}

# do_secrets_check_gcp - the Secret Manager check (the body of
# do_spl_secrets_check before spec 076, unchanged).
do_secrets_check_gcp() {
  do_require_bin gcloud yq python3 || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local rows
  rows="$(spl_secrets_slots)" || return 1

  local slot envvar req kind seed state bad=0 n=0
  while IFS=$'\t' read -r slot envvar req kind seed; do
    [[ -n "$slot" ]] || continue
    n=$((n + 1))
    seed="${seed:-<no seed action known for $envvar>}"
    state="$(spl_secret_state "$slot")"
    case "$state:$req" in
      enabled:*)        do_log "OK      $slot ($req, $kind)" ;;
      empty:required)   do_log "EMPTY   $slot (required, $envvar): seed it: ENV=$ENV DRY_RUN=0 $seed"; bad=$((bad + 1)) ;;
      empty:*)          do_log "INFO    $slot (optional, no version): when wanted: ENV=$ENV DRY_RUN=0 $seed" ;;
      missing:required) do_log "MISSING $slot (required, $envvar): no such slot in $SPL_PROJECT: apply $(spl_secret_step "$envvar") first, then $seed"; bad=$((bad + 1)) ;;
      *)                do_log "INFO    $slot (optional): no such slot in $SPL_PROJECT yet" ;;
    esac
  done <<<"$rows"

  (( bad == 0 )) || { do_log "FAIL $bad of $n secret slot(s) in $SPL_PROJECT block the hub: run the seeds named above, or ENV=$ENV DRY_RUN=0 ./run -a do_spl_secrets_seed_all"; return 1; }
  do_log "OK every required secret slot of $SPL_PROJECT has an enabled version ($n slot(s) checked, no value read)"
}

# spl_secrets_slots -> one TSV row per secret slot of $ENV, in seed order:
#   <slot> <ENV_VAR> <required|optional> <gen|ask> <seed command>
# gen: its seed makes the value itself; ask: it needs an outside value (SMTP,
# IdP, payment) from an owner file. Reads the rendered 030 / 040 tfvars, and
# the cnf secret_env maps for the env var of a slot 030 does not inject, and
# the two optional public dataset login slots of cnf public_dataset (091 T004).
spl_secrets_slots() {
  local dir="${SPL_TFVARS_DIR:-$APP_PATH/$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV/tf}"
  local f030="$dir/030-cloud-run-hub.vars.tfvars" f040="$dir/040-cloud-sql-postgres.vars.tfvars"
  [[ -f "$f030" && -f "$f040" ]] ||
    { do_log "FATAL no rendered 030/040 tfvars in $dir: render them first (ENV=$ENV ./run -a do_tpl_gen in $SPL_ORG_APP-iac)"; return 1; }
  local maps
  maps="$(yq -o=json '[.. | select(tag == "!!map") | select(has("secret_env")) | .secret_env]' "$SPL_CNF")" ||
    { do_log "FATAL cannot read the secret_env maps of $SPL_CNF"; return 1; }
  # spec 091 T004: the public dataset logins' password slots (no terraform
  # step makes them; their seed creates them), never read by the hub
  local public
  public="$(yq -o=json '[.env.public_dataset.export_password_secret // "", .env.public_dataset.names_password_secret // ""]' "$SPL_CNF")" ||
    { do_log "FATAL cannot read cnf public_dataset of $SPL_CNF"; return 1; }
  SPL_SECRET_ENV_MAPS="$maps" SPL_PUBLIC_SLOTS="$public" python3 - "$f030" "$f040" <<'PY'
import json, os, re, sys

def tfvars(path):
    out = {}
    for line in open(path):
        m = re.match(r'^\s*([a-z_]+)\s*=\s*(.+?)\s*$', line)
        if m:
            try:
                out[m.group(1)] = json.loads(m.group(2))
            except ValueError:
                pass
    return out

v30, v40 = tfvars(sys.argv[1]), tfvars(sys.argv[2])
injected = {s: e for e, s in (v30.get("secret_environment_variables") or {}).items()}
by_slot = {}
for m in json.loads(os.environ["SPL_SECRET_ENV_MAPS"]):
    for e, s in (m or {}).items():
        by_slot.setdefault(s, e)
by_slot.update(injected)

GEN = {
    "SPOOL_HUB_DB_DSN": "./run -a do_spl_db_bootstrap",
    "SPOOL_HUB_DB_OWNER_DSN": "./run -a do_spl_db_bootstrap",
    "SPOOL_HUB_AUTH_SESSION_KEY": "./run -a do_spl_auth_secrets_seed",
    "SPOOL_HUB_WUI_KEY": "./run -a do_spl_wui_key_seed",
    "SPOOL_HUB_RELEASE_NOTE_BANS": "./run -a do_spl_release_note_bans_seed",
    "PUBLIC_EXPORT_DB_PASSWORD": "./run -a do_spl_public_export_secret_seed",
    "PUBLIC_NAMES_DB_PASSWORD": "./run -a do_spl_public_export_secret_seed",
}
ASK = {
    "SPOOL_HUB_MAIL_SMTP_PASSWORD": "./run -a do_spl_mail_secret_seed",
    "SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET": "./run -a do_spl_auth_secrets_seed",
    **{f"SPOOL_HUB_AUTH_{i}_CLIENT_SECRET": f"IDP={i.lower()} ./run -a do_spl_auth_idp_secret_seed"
       for i in ("FACEBOOK", "MICROSOFT", "LINKEDIN", "XAI")},
    "SPOOL_HUB_STRIPE_SECRET_KEY": "./run -a do_spl_payment_secret_seed",
    "SPOOL_HUB_PAYPAL_CLIENT_SECRET": "./run -a do_spl_payment_secret_seed",
    "SPOOL_HUB_STRIPE_WEBHOOK_SECRET": "STRIPE_API_BASE=<stripe-api-base> ./run -a do_spl_provision_stripe_endpoints",
}
ORDER = list(GEN) + list(ASK)

rows = {}
def add(slot, envvar, req):
    if slot and slot not in rows:
        envvar = envvar or "-"
        kind, cmd = ("gen", GEN[envvar]) if envvar in GEN else ("ask", ASK.get(envvar, ""))
        rows[slot] = (slot, envvar, req, kind, cmd)

add(v40.get("dsn_secret_id"), "SPOOL_HUB_DB_DSN", "required")
add(v40.get("owner_dsn_secret_id"), "SPOOL_HUB_DB_OWNER_DSN", "required")
for s, e in injected.items():
    add(s, e, "required")
for s in v30.get("auth_secret_ids") or []:
    add(s, by_slot.get(s, ""), "optional")
for s, e in zip(json.loads(os.environ["SPL_PUBLIC_SLOTS"]), ("PUBLIC_EXPORT_DB_PASSWORD", "PUBLIC_NAMES_DB_PASSWORD")):
    add(s, e, "optional")
if not rows:
    sys.exit("no secret slot in the rendered 030/040 tfvars")
rank = lambda r: (ORDER.index(r[1]) if r[1] in ORDER else len(ORDER), r[0])
for r in sorted(rows.values(), key=rank):
    print("\t".join(r))
PY
}

# spl_secret_state <slot> -> enabled | empty | missing, from `versions list`
# only: a value is never read.
spl_secret_state() {
  local out
  out="$(gcloud secrets versions list "$1" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
    --filter='state=ENABLED' --format='value(name)' --limit=1 2>/dev/null)" || { echo missing; return 0; }
  [[ -n "$out" ]] && echo enabled || echo empty
}

# spl_secret_step <ENV_VAR> -> the terraform step that creates its slot
spl_secret_step() {
  case "$1" in
    SPOOL_HUB_DB_DSN|SPOOL_HUB_DB_OWNER_DSN) echo "ENV=$ENV STEP=040-cloud-sql-postgres" ;;
    *) echo "ENV=$ENV STEP=030-cloud-run-hub" ;;
  esac
}

# ------------------------------------------------------------ provider none ---
# A self-hosted compose box keeps its secrets in two places (spec 076 4.2 and
# 5.2 item 4), never in a cloud: the .env next to docker-compose.yml (mode
# 600, written by do_spl_self_host_up) and the hub state dir, which holds
# session.key (minted by hub-init, hub-entrypoint.sh). No gcloud; only key
# names, states and file modes are ever printed, never a value.

# spl_secrets_none_paths - sets envf (the .env) and statef (session.key)
spl_secrets_none_paths() {
  local dir="${SPOOL_SELF_HOST_DIR:-${APP_PATH:-}}"
  [[ -n "$dir" ]] || { do_log "FATAL no self-host dir: set SPOOL_SELF_HOST_DIR (the dir holding docker-compose.yml and .env)"; return 1; }
  envf="$dir/.env"
  statef="${SPOOL_STATE_DIR:-/var/lib/spool/state}/session.key"
}

# spl_secrets_none_rows <envf> -> one TSV row per .env secret, in seed order:
#   <KEY> <required|optional> <gen|ask>
# gen: seed-all mints it (the three Postgres passwords of do_spl_self_host_up);
# ask: an outside value. The SMTP password is required only when the .env
# sends mail over SMTP.
spl_secrets_none_rows() {
  local k req=optional
  for k in SPOOL_DB_OWNER_PASSWORD SPOOL_DB_RUNTIME_PASSWORD SPOOL_DB_SUPERUSER_PASSWORD; do
    printf '%s\trequired\tgen\n' "$k"
  done
  [[ "$(spl_secrets_none_get "$1" SPOOL_MAIL_TRANSPORT)" == smtp ]] && req=required
  printf 'SPOOL_MAIL_SMTP_PASSWORD\t%s\task\n' "$req"
}

# spl_secrets_none_get <file> <KEY> - the value of KEY=... in a dotenv file
# (quotes stripped), empty when absent. Never sources the file.
spl_secrets_none_get() {
  [[ -f "$1" ]] || return 0
  local line v
  line="$(grep -E "^$2=" "$1" | tail -n 1)" || return 0
  v="${line#*=}"
  if [[ ${#v} -ge 2 && ( "$v" == \'*\' || "$v" == \"*\" ) ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

# spl_secrets_none_state <value> -> set | empty | default. An .env.example
# placeholder (<...>) is empty; the compose default (spool-local-*) is public.
spl_secrets_none_state() {
  case "$1" in
    "" | "<"*) echo empty ;;
    spool-local-*) echo default ;;
    *) echo set ;;
  esac
}

# spl_secrets_none_mode <file> -> its octal mode, e.g. 600
spl_secrets_none_mode() { stat -c '%a' "$1" 2>/dev/null; }

do_secrets_check_none() {
  local envf statef
  spl_secrets_none_paths || return 1
  local seed="DRY_RUN=0 ./run -a do_spl_secrets_seed_all"
  local key req kind state mode bad=0 n=0

  if [[ ! -f "$envf" ]]; then
    do_log "MISSING $envf: no .env: run ./run -a do_spl_self_host_up, or $seed"; bad=$((bad + 1))
  else
    mode="$(spl_secrets_none_mode "$envf")"
    [[ "$mode" == 600 ]] || { do_log "MODE    $envf is $mode, not 600: chmod 600 $envf (or $seed)"; bad=$((bad + 1)); }
    while IFS=$'\t' read -r key req kind; do
      n=$((n + 1))
      state="$(spl_secrets_none_state "$(spl_secrets_none_get "$envf" "$key")")"
      case "$state:$req:$kind" in
        set:*)              do_log "OK      $key ($req, $kind)" ;;
        empty:required:gen) do_log "EMPTY   $key (required): seed it: $seed"; bad=$((bad + 1)) ;;
        empty:required:ask) do_log "EMPTY   $key (required, SPOOL_MAIL_TRANSPORT=smtp): set it in $envf, or re-run ./run -a do_spl_self_host_up"; bad=$((bad + 1)) ;;
        default:required:*) do_log "DEFAULT $key (required) is the public compose default: rotate it in Postgres, then in $envf"; bad=$((bad + 1)) ;;
        *)                  do_log "INFO    $key (optional): not set" ;;
      esac
    done < <(spl_secrets_none_rows "$envf")
  fi

  n=$((n + 1))
  if [[ ! -d "${statef%/*}" ]]; then
    do_log "INFO    session.key: no state dir ${statef%/*} on this host: hub-init mints it into the hub-state volume"
  elif [[ ! -s "$statef" ]]; then
    do_log "EMPTY   session.key (required): seed it: $seed"; bad=$((bad + 1))
  else
    mode="$(spl_secrets_none_mode "$statef")"
    if [[ "$mode" == 600 ]]; then do_log "OK      session.key (required, gen)"
    else do_log "MODE    $statef is $mode, not 600: chmod 600 $statef (or $seed)"; bad=$((bad + 1)); fi
  fi

  (( bad == 0 )) || { do_log "FAIL $bad self-host secret problem(s) block the hub: fix the lines above, or $seed"; return 1; }
  do_log "OK every required self-host secret is set ($n checked, no value printed)"
}
