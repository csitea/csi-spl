#!/bin/bash
#------------------------------------------------------------------------------
# @description M3 end to end on a CLOUD env (dev first): authenticated humans
# @description chat with agents and command them on the same v:1 bus. The
# @description repeatable proof behind 014 acceptance, 005 SC-001 and the dev
# @description part of 006 T011c (record: csi-spl-doc/specs/014-spool-wui-dispatch/
# @description acceptance-dev.md). Steps, each printed PASS/FAIL with evidence:
# @description   0  two box clients on THIS machine (box-e2e-a / box-e2e-b, own
# @description      key + SPOOL_ROOT each) pinned by the tenant root key, and
# @description      the hub's box-wui key pinned (--force: dev's key is
# @description      ephemeral, a hub restart mints a new one)
# @description   a  box-a -> box-b `spool send`, drained by hub-sync, listed by
# @description      /v1/view/threads (the WUI viewer's API)
# @description   b  a member human on /v1/wui/ws: an ambient #lobby note
# @description      reaches no box; a leading @EZB-1 mention does
# @description   c  a task to EZB-1 is box-wui SIGNED; box-b's hub-run verifies
# @description      it on its local box-wui pin; its kind=result reaches the
# @description      browser's thread
# @description   d  DM (no channel) human <-> agent; presence online/offline
# @description      as box-b's hub-run connects / stops
# @description   e1 CONTROL forged / unsigned copies of the signed task, replayed
# @description      to a clone of box-b by a local fake hub: exit 78, nothing
# @description      written (a genuine copy: exit 0, written)
# @description   e2 CONTROL a never-invited human: login for the tenant 403
# @description      not_allowed; its tenant-less session cannot dispatch
# @description The member human is a native (015) account; the dev hub's
# @description debug tokens verify it. The FIRST run of a state dir seats it
# @description with `spool hub-invite --role member` over the Cloud SQL proxy
# @description (010 T018) BEFORE it ever signs in with the tenant: on a
# @description zero-member tenant with bootstrap on, a first sign-in would make
# @description the test account the tenant OWNER. Later runs reuse the marker.
# @description Secrets (root key, passwords, cookies) stay in 0600 files under
# @description the state dir; the log carries none of them.
# @description
# @description ENV=prd mode (CLE-3396): prd refuses debug tokens and its t1 is
# @description the owner's REAL tenant, so:
# @description   - only a test tenant runs (TENANT_ID ^e2e(-[a-z0-9]+)?$, default e2e);
# @description     t1 or any other name is refused before anything happens
# @description   - no ROOT_KEY_JSON: the newest $SPL_TENANTS_DIR/<tenant>.*.json;
# @description     none and M3_CREATE_TENANT=1: do_spl_tenant_create (DRY_RUN=0)
# @description     writes it there (0600, dir 0700) - the tenant stays, see the
# @description     acceptance-prd record for its id and how to remove it
# @description   - the humans are plus-addresses of the relay mailbox (cnf
# @description     mail.env.SPOOL_HUB_MAIL_SMTP_USER): <local>+spl-e2e-<utc>@ and
# @description     <local>+spl-e2e-out-<utc>@, fixed per state dir on first run
# @description   - the verify mail is read over IMAP with the relay password (cnf
# @description     mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD, read as the prd
# @description     project SA in a throwaway CLOUDSDK_CONFIG into a 0600 file that
# @description     is removed when the run ends); its token goes to the hub's
# @description     verify API, the link's WUI page is probed and recorded
# @description   - the human is seated as the test tenant's OWNER (invite path,
# @description     M3_HUMAN_ROLE; dev keeps member)
# @param ENV - required: dev or prd
# @param TENANT_ID - dev: required (t1). prd: a test tenant ^e2e(-[a-z0-9]+)?$, default e2e
# @param ROOT_KEY_JSON - dev: required; prd: default the newest
# @param   $SPL_TENANTS_DIR/<tenant>.*.json. The 0600 JSON do_spl_tenant_create
# @param   wrote (field root_private_key); or ROOT_KEY = a root.key file instead
# @param M3_CREATE_TENANT (optional) - prd: 1 = create the test tenant when no key JSON exists
# @param SPL_TENANTS_DIR (optional) - default /var/<org>/<org>-<app>/tenants/<env>
# @param M3_HUMAN_EMAIL (optional) - dev default m3-e2e-human@example.com; prd a plus-address
# @param M3_OUTSIDER_EMAIL (optional) - never invited; dev default m3-e2e-outsider@example.com
# @param M3_HUMAN_ROLE (optional) - the invite role: dev member, prd owner
# @param SPL_SA_KEY (optional) - the env's service-account key for the invite
# @param   (DSN read + Cloud SQL proxy); default $HOME/.gcp/.<org>/key-<project>.json.
# @param   Activated in a throwaway CLOUDSDK_CONFIG, never the owner account
# @param   (owner rule 2026-09-19). Only used when an invite is needed.
# @param SPL_STATE_DIR (optional) - default $HOME/.local/share/<org>-<app>/cloud/<env>
# @example ENV=dev TENANT_ID=t1 ROOT_KEY_JSON=/var/csi/csi-spl/tenants/dev/t1.<ts>.json ./run -a do_spl_m3_e2e
# @example ENV=prd M3_CREATE_TENANT=1 ./run -a do_spl_m3_e2e
#------------------------------------------------------------------------------
do_spl_m3_e2e() {
  do_require_bin yq python3 curl || return 1
  [[ "${ENV:-}" == prd ]] && TENANT_ID="${TENANT_ID:-e2e}"
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  if [[ "$ENV" == prd ]]; then
    spl_m3_prd_prepare "$tenant" || return 1
  fi

  local st="$SPL_STATE_DIR/m3-e2e/$tenant"
  mkdir -p "$st" && chmod 700 "$st" || return 1
  local key="$st/root.key"
  ( umask 077
    if [[ -n "${ROOT_KEY_JSON:-}" ]]; then
      python3 -c 'import json,sys; open(sys.argv[2],"w").write(json.load(open(sys.argv[1]))["root_private_key"].strip()+"\n")' \
        "$ROOT_KEY_JSON" "$key"
    elif [[ -n "${ROOT_KEY:-}" ]]; then
      cp "$ROOT_KEY" "$key"
    else
      false
    fi ) 2>/dev/null || { do_log "FATAL need ROOT_KEY_JSON (field root_private_key) or ROOT_KEY for tenant $tenant"; return 1; }
  [[ -s "$key" ]] || { do_log "FATAL empty tenant root key from ${ROOT_KEY_JSON:-$ROOT_KEY}"; return 1; }

  spl_host_spool || return 1

  local role="${M3_HUMAN_ROLE:-member}"
  if [[ "$ENV" == prd ]]; then
    role="${M3_HUMAN_ROLE:-owner}"
    spl_m3_prd_humans "$st" || return 1
  fi
  # One host (specs/026): boxes, the viewer API, the WUI socket and auth all use
  # the API host (env.dns.api_fqdn); the tenant comes from the session and the
  # box pin (SPOOL_TENANT). M3_HUB_URL=https://<tenant>.<fqdn> still runs the
  # legacy tenant-host path while that mapping exists.
  local api_fqdn
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api_fqdn" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  export M3_HUB_URL="${M3_HUB_URL:-https://$api_fqdn}" M3_TENANT="$tenant" M3_AUTH_URL="https://$api_fqdn" M3_STATE="$st" \
    M3_SPOOL="$SPL_SPOOL" M3_ROOT_KEY="$key" \
    M3_HUMAN_EMAIL="${M3_HUMAN_EMAIL:-m3-e2e-human@example.com}" \
    M3_OUTSIDER_EMAIL="${M3_OUTSIDER_EMAIL:-m3-e2e-outsider@example.com}"
  local py="$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/m3-e2e.py" rc=0
  do_log "INFO M3 e2e on $ENV/$tenant: hub $M3_HUB_URL auth $M3_AUTH_URL human $M3_HUMAN_EMAIL ($role)"
  python3 "$py" auth-check || rc=$?
  if [[ $rc == 3 ]]; then
    spl_m3_invite "$tenant" "$M3_HUMAN_EMAIL" "$role" || { spl_m3_imap_forget; return 1; }
    rc=0; M3_INVITED=1 python3 "$py" auth-check || rc=$?
  fi
  [[ $rc == 0 ]] || { spl_m3_imap_forget; do_log "FATAL the member human cannot sign in to $tenant (auth-check exit $rc)"; return 1; }

  rc=0; python3 "$py" run || rc=$?
  spl_m3_imap_forget
  [[ $rc == 0 ]] || { do_log "FAIL M3 e2e on $ENV/$tenant: see $st/results.json"; return 1; }
  do_log "OK M3 e2e on $ENV/$tenant: every step PASS ($st/results.json)"
}

# spl_m3_prd_prepare <tenant>: the prd guards and the tenant key. Only a test
# tenant (^e2e(-[a-z0-9]+)?$) runs: prd t1 is the owner's real tenant, and this
# harness pins boxes, invites humans and writes messages into its tenant.
spl_m3_prd_prepare() {
  local tenant="$1"
  [[ "$tenant" =~ ^e2e(-[a-z0-9]+)?$ ]] || {
    do_log "FATAL prd runs only in a test tenant (^e2e(-[a-z0-9]+)?$), got '$tenant': prd tenants are real"; return 1; }
  [[ -n "${ROOT_KEY_JSON:-}${ROOT_KEY:-}" ]] && return 0
  local org="${SPL_ORG_APP%%-*}" dir
  dir="${SPL_TENANTS_DIR:-/var/$org/$SPL_ORG_APP/tenants/$ENV}"
  ROOT_KEY_JSON="$(ls -1 "$dir/$tenant".*.json 2>/dev/null | sort | tail -n 1)"
  if [[ -z "$ROOT_KEY_JSON" ]]; then
    [[ "${M3_CREATE_TENANT:-0}" == 1 ]] || {
      do_log "FATAL no $dir/$tenant.*.json: create the test tenant with M3_CREATE_TENANT=1 (or pass ROOT_KEY_JSON)"; return 1; }
    ( umask 077; mkdir -p "$dir" && chmod 700 "$dir" ) || return 1
    local out
    out="$dir/$tenant.$(date -u +%Y%m%dT%H%M%SZ).json"
    ( umask 077; RUN_STDOUT_IS_DATA=1 ENV="$ENV" DRY_RUN=0 TENANT_ID="$tenant" do_spl_tenant_create >"$out" ) || {
      rm -f "$out"; do_log "FATAL do_spl_tenant_create $tenant failed (no key kept)"; return 1; }
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["root_private_key"] and d["tenant"]==sys.argv[2]' \
      "$out" "$tenant" 2>/dev/null || { do_log "FATAL $out holds no root key for $tenant"; return 1; }
    do_log "OK created prd test tenant $tenant; root key JSON $out (0600)"
    ROOT_KEY_JSON="$out"
  fi
  export ROOT_KEY_JSON
  do_log "INFO tenant $tenant root key JSON: $ROOT_KEY_JSON"
}

# spl_m3_prd_humans <state dir>: the member and the outsider as plus-addresses
# of the relay mailbox (fixed per state dir, so a re-run signs in with the
# stored passwords), and the relay password for IMAP in a 0600 file.
spl_m3_prd_humans() {
  local st="$1" user local_part domain ts
  user="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  [[ "$user" == *@* ]] || { do_log "FATAL no mail.env.SPOOL_HUB_MAIL_SMTP_USER in the $ENV cnf (the IMAP mailbox)"; return 1; }
  local_part="${user%@*}" domain="${user#*@}" ts="$(date -u +%Y%m%dT%H%M%SZ)"
  [[ -s "$st/human-email" ]] || printf '%s+spl-e2e-%s@%s\n' "$local_part" "$ts" "$domain" >"$st/human-email"
  [[ -s "$st/outsider-email" ]] || printf '%s+spl-e2e-out-%s@%s\n' "$local_part" "$ts" "$domain" >"$st/outsider-email"
  M3_HUMAN_EMAIL="${M3_HUMAN_EMAIL:-$(cat "$st/human-email")}"
  M3_OUTSIDER_EMAIL="${M3_OUTSIDER_EMAIL:-$(cat "$st/outsider-email")}"
  local host
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  export M3_IMAP_USER="$user" M3_IMAP_HOST="${M3_IMAP_HOST:-imap.${host#smtp.}}" M3_IMAP_PASS_FILE="$st/imap-pass"
  spl_m3_imap_pass "$M3_IMAP_PASS_FILE"
}

# spl_m3_imap_pass <file>: the relay password (cnf slot
# mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD) into a 0600 file, read as the
# env's project SA in a throwaway CLOUDSDK_CONFIG. Never argv, stdout or a log.
spl_m3_imap_pass() {
  local f="$1" slot
  slot="$(yq -r '.env.mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD // ""' "$SPL_CNF")"
  [[ -n "$slot" ]] || { do_log "FATAL no mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD in the $ENV cnf"; return 1; }
  (
    do_gcp_pin_account "$SPL_CNF" || exit 1
    umask 077
    gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
      >"$f" 2>/dev/null || { rm -f "$f"; do_log "FATAL cannot read $slot in $SPL_PROJECT as $GCP_ACCOUNT"; exit 1; }
    [[ -s "$f" ]] || { rm -f "$f"; do_log "FATAL $slot in $SPL_PROJECT is empty"; exit 1; }
    do_log "OK the relay password for IMAP is in a 0600 file for this run ($slot, $GCP_ACCOUNT)"
  )
}

spl_m3_imap_forget() {
  [[ -n "${M3_IMAP_PASS_FILE:-}" ]] && rm -f "$M3_IMAP_PASS_FILE"
  return 0
}

# spl_m3_invite <tenant> <email> [role]: `spool hub-invite --role <role>` (default member) through the
# Cloud SQL proxy (the path do_spl_tenant_create uses), as the env's service
# account in a throwaway gcloud config (never the owner account, never the
# shared ~/.config/gcloud). The DSN stays in a local.
spl_m3_invite() {
  local key="${SPL_SA_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-$SPL_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $key (set SPL_SA_KEY)"; return 1; }
  local cfg
  cfg="$(mktemp -d)" || return 1
  (
    export CLOUDSDK_CONFIG="$cfg"
    gcloud auth activate-service-account --key-file="$key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $key"; exit 1; }
    GCP_ACCOUNT="$(do_gcp_isolated_active_account)" || exit 1
    export GCP_ACCOUNT
    local cloud_dsn dsn out rc
    cloud_dsn="$(spl_read_dsn)"
    [[ -n "$cloud_dsn" ]] || { do_log "FATAL cannot read $SPL_DSN_SECRET in $SPL_PROJECT as $GCP_ACCOUNT"; exit 1; }
    spl_sql_proxy_start || exit 1
    dsn="$(spl_proxy_dsn "$cloud_dsn" "$SPL_PROXY_PORT")" || { spl_sql_proxy_stop; do_log "FATAL unexpected DSN shape in $SPL_DSN_SECRET"; exit 1; }
    out="$(SPOOL_HUB_DB_DSN="$dsn" "$SPL_SPOOL" hub-invite --tenant "$1" --email "$2" --role "${3:-member}" 2>&1)"
    rc=$?
    spl_sql_proxy_stop
    [[ $rc == 0 ]] || { do_log "FATAL hub-invite $2 to $1: $out"; exit 1; }
    do_log "OK invited $2 to $1 as ${3:-member} ($GCP_ACCOUNT): $out"
  )
  local rc=$?
  rm -rf "$cfg"
  return $rc
}
