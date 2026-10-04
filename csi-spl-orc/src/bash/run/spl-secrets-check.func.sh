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
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param SPL_TFVARS_DIR (optional) - default: the rendered <org>-<app>-cnf/<org>-<app>/<env>/tf
# @example ENV=dev ./run -a do_spl_secrets_check
#------------------------------------------------------------------------------
do_spl_secrets_check() {
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
# the cnf secret_env maps for the env var of a slot 030 does not inject.
spl_secrets_slots() {
  local dir="${SPL_TFVARS_DIR:-$APP_PATH/$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV/tf}"
  local f030="$dir/030-cloud-run-hub.vars.tfvars" f040="$dir/040-cloud-sql-postgres.vars.tfvars"
  [[ -f "$f030" && -f "$f040" ]] ||
    { do_log "FATAL no rendered 030/040 tfvars in $dir: render them first (ENV=$ENV ./run -a do_tpl_gen in $SPL_ORG_APP-iac)"; return 1; }
  local maps
  maps="$(yq -o=json '[.. | select(tag == "!!map") | select(has("secret_env")) | .secret_env]' "$SPL_CNF")" ||
    { do_log "FATAL cannot read the secret_env maps of $SPL_CNF"; return 1; }
  SPL_SECRET_ENV_MAPS="$maps" python3 - "$f030" "$f040" <<'PY'
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
