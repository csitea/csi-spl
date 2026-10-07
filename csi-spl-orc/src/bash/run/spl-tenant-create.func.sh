#!/bin/bash
#------------------------------------------------------------------------------
# @description Create a spool-hub tenant (006 T003). Prints JSON on stdout:
# @description tenant id, hub URL, root pubkey, and (DRY_RUN=0 only) the
# @description tenant-root PRIVATE key once. The hub DB stores the 32-byte
# @description public key only. billing_status=manual. URL is built from cnf
# @description SPOOL_HUB_TENANT_HOST_PATTERN — no hostname is baked in.
# @description DRY_RUN=1 (default): print the URL, do not generate a key or
# @description INSERT. The private key is never passed to do_log.
# @param TENANT_ID - DNS slug ^[a-z0-9][a-z0-9-]{0,31}$, not a reserved label
# @param TENANT_ID   (dev, prd, www, api, ...: the hub refuses those at create)
# @param ENV (optional) - lde (default), dev or prd
# @param DRY_RUN (optional) - 1 (default): no key, no INSERT. 0: create.
# @param SPOOL_HUB_DB_DSN (optional) - lde: derived. dev/prd: when unset, the
# @param   DSN secret is read as GCP_ACCOUNT and reached through the Cloud SQL
# @param   proxy (spl_sql_proxy_start), the same path do_spl_db_bootstrap uses
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account). dev/prd with DRY_RUN=0 and no SPOOL_HUB_DB_DSN: the
# @param   operator (secretmanager.secretAccessor + cloudsql.client)
# @param SPOOL_BIN (optional) - spool CLI; otherwise built from csi-spl-api
# @description dev/prd: boxes use the API host with SPOOL_TENANT=<id> (specs/026).
# @description SPL-959: where cnf steps.019 wui_tenant_hosts is on, "url" is the
# @description tenant's WUI host https://<id>.<fqdn>, and a DRY_RUN=0 create
# @description CHAINS do_spl_tenant_host_provision: env.dns.mapped_tenants += id,
# @description render 019 + 025, that cnf PUSHED to the trunk by the action
# @description (throwaway worktree; a push that does not land fails it), apply,
# @description cert, WUI probe, tenant_hosts ready + the ready notice. Its log
# @description goes to stderr, so stdout stays the one JSON line. Exit 3 =
# @description created, host not ready (a failed push included).
# @param TENANT_HOST (optional) - 1 (default): chain the host; 0: skip it
# @param CNF_PUSH (optional) - 1 (default): push the cnf change before the apply
# @param   (run from the main checkout, the tree the tf-runner mounts); 0: leave
# @param   it uncommitted (warned loudly)
# @description SPL-1290: a dev/prd DRY_RUN=0 create also PINS the hub's box-wui
# @description key under the new tenant (do_spl_cloud_pin_box_wui, signed with
# @description the root key while it is still in hand). Without that pin every
# @description browser post is stored unsigned and no agent receives it (prd
# @description csitea, leiden, pas-psf and four more, found 2026-10-01,
# @description CLE-77876). Exit 4 = created, box-wui not pinned.
# @param TENANT_PIN_WUI (optional) - 1 (default): pin box-wui; 0: skip it
# @example TENANT_ID=acme ./run -a do_spl_tenant_create --json
# @example ENV=lde DRY_RUN=0 TENANT_ID=acme ./run -a do_spl_tenant_create --json
# @example ENV=dev DRY_RUN=0 TENANT_ID=t1 ./run -a do_spl_tenant_create
#------------------------------------------------------------------------------
do_spl_tenant_create() {
  do_require_bin yq || return 1
  local tenant="${TENANT_ID:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || {
    do_log "FATAL TENANT_ID must match ^[a-z0-9][a-z0-9-]{0,31}$ (pretty DNS slug), got: '${tenant}'"
    return 1
  }

  local env="${ENV:-lde}" dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }

  local pattern url host dsn=""
  _spl_tenant_create_target "$tenant" "$env" || return 1

  [[ "$env" == lde ]] || do_log "INFO specs/026: $tenant needs no host or DNS - members sign in with ?tenant=$tenant, boxes use the API host with SPOOL_TENANT=$tenant"

  if [[ "$dry" == 1 ]]; then
    do_log "INFO DRY_RUN would INSERT tenant $tenant (pubkey only, billing_status=manual) and print the root private key once"
    printf '{"tenant":"%s","url":"%s","billing_status":"manual","dry_run":true,"would":"generate root keypair; INSERT tenants root_pubkey only"}\n' \
      "$tenant" "$url"
    do_log "OK DRY_RUN tenant $tenant url=$url (no key generated, nothing inserted)"
    return 0
  fi

  local cli="${SPOOL_BIN:-}"
  _spl_tenant_create_cli || return 1

  # dev/prd with no DSN given: read the DSN secret and reach Cloud SQL through
  # the local proxy. Every failure here happens before a key is generated.
  local proxied=0
  if [[ -z "$dsn" && "$env" != lde ]]; then
    _spl_tenant_create_cloud_dsn || return 1
  fi

  [[ -n "$dsn" ]] || {
    do_log "FATAL SPOOL_HUB_DB_DSN is required when DRY_RUN=0 (lde: derived; dev/prd: read from the DSN secret)"
    return 1
  }

  local tmp pub priv
  tmp="$(mktemp -d)" || { [[ $proxied == 1 ]] && spl_sql_proxy_stop; return 1; }
  chmod 700 "$tmp" || { [[ $proxied == 1 ]] && spl_sql_proxy_stop; return 1; }
  # shellcheck disable=SC2064
  if [[ $proxied == 1 ]]; then
    trap "rm -rf '$tmp'; spl_sql_proxy_stop; trap - RETURN" RETURN
  else
    trap "rm -rf '$tmp'; trap - RETURN" RETURN
  fi

  pub="$("$cli" root-keygen --out "$tmp/root.key")" || {
    do_log "FATAL root-keygen failed"
    return 1
  }
  priv="$(tr -d '\n' <"$tmp/root.key")"
  rm -f "$tmp/root.key"

  local err
  if ! err="$("$cli" hub-tenant --tenant "$tenant" --root-pubkey "$pub" --billing-status manual \
      --db "$dsn" 2>&1 >/dev/null)"; then
    do_log "FATAL hub-tenant refused $tenant: ${err:-no detail}; the private key was NOT printed"
    return 1
  fi

  printf '{"tenant":"%s","url":"%s","root_pubkey":"%s","root_private_key":"%s","billing_status":"manual"}\n' \
    "$tenant" "$url" "$pub" "$priv"
  do_log "OK created tenant $tenant url=$url (root private key printed once on stdout, not stored)"
  [[ "$env" == lde ]] && return 0
  spl_tenant_create_pin_wui "$tenant" "$url" "$pub" "$priv" "$tmp" >&2 || {
    do_log "WARN tenant $tenant exists, but box-wui is NOT pinned: its people's posts reach no agent until ENV=$env TENANT_ID=$tenant TENANT_FILE=<the saved create JSON> DRY_RUN=0 ./run -a do_spl_cloud_pin_box_wui" >&2
    return 4
  }
  ENV="$env" spl_tenant_create_host "$tenant" >&2 || {
    do_log "WARN tenant $tenant exists, but its host $url is not ready: re-run ENV=$env TENANT_ID=$tenant DRY_RUN=0 ./run -a do_spl_tenant_host_provision" >&2
    return 3
  }
}

# _spl_tenant_create_target <tenant> <env>: the hub a tenant is created on -
# sets the caller's pattern, host, url and (lde) dsn from the env's cnf, and
# refuses an env other than lde/dev/prd or a host pattern that is not
# {tenant}.<fqdn>.
_spl_tenant_create_target() {
  local tenant="$1" env="$2"
  case "$env" in
    lde)
      do_lde_cnf || return 1
      pattern="$(yq -r '.env.hub.env.SPOOL_HUB_TENANT_HOST_PATTERN // ""' "$LDE_CNF")"
      host="${pattern/"{tenant}"/$tenant}"
      url="http://${host}:${LDE_HUB_PORT}"
      dsn="postgres://${LDE_PG_USER}:${LDE_PG_PASSWORD}@127.0.0.1:${LDE_PG_PORT}/${LDE_PG_DB}?sslmode=disable"
      ;;
    dev|prd)
      ENV="$env" do_spl_cloud_cnf || return 1
      pattern="$(yq -r '.env.hub.env.SPOOL_HUB_TENANT_HOST_PATTERN // ""' "$SPL_CNF")"
      host="${pattern/"{tenant}"/$tenant}"
      url="https://${host}"
      dsn="${SPOOL_HUB_DB_DSN:-}"
      ;;
    *)
      do_log "FATAL ENV must be lde, dev or prd, got: '$env'"
      return 1
      ;;
  esac
  case "$pattern" in
    "{tenant}."*) ;;
    *)
      do_log "FATAL SPOOL_HUB_TENANT_HOST_PATTERN must look like {tenant}.<fqdn>, got: '$pattern'"
      return 1
      ;;
  esac
  [[ ${#pattern} -gt 10 ]] || {
    do_log "FATAL SPOOL_HUB_TENANT_HOST_PATTERN must look like {tenant}.<fqdn>, got: '$pattern'"
    return 1
  }
}

# _spl_tenant_create_cli: sets the caller's cli to SPOOL_BIN when it is an
# executable, else to a spool CLI built from this tree into the state dir.
_spl_tenant_create_cli() {
  [[ -n "$cli" && -x "$cli" ]] && return 0
  local out="${LDE_STATE_DIR:-${SPL_STATE_DIR:-/tmp}}/bin/spool"
  mkdir -p "$(dirname "$out")" || return 1
  bash "$APP_PATH/csi-spl-api/src/bash/build.sh" "$out" >/dev/null || {
    do_log "FATAL spool build failed"
    return 1
  }
  cli="$out"
}

# _spl_tenant_create_cloud_dsn: reads the runtime DSN and reaches it locally.
# Under gcp that pins the env's service account and starts the Cloud SQL proxy
# (spl_local_dsn is spl_proxy_dsn). Under none no account is pinned and the
# DSN is the local Postgres one. Sets the caller's dsn and proxied=1 (the
# proxy is stopped again when the DSN cannot be rewritten).
_spl_tenant_create_cloud_dsn() {
  if [[ "$(do_spl_cloud_provider)" != none ]]; then
    do_gcp_pin_account "${SPL_CNF:-}" || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  fi
  local cloud_dsn
  cloud_dsn="$(spl_read_dsn)"
  [[ -n "$cloud_dsn" ]] || { do_log "FATAL cannot read $SPL_DSN_SECRET in $SPL_PROJECT as ${GCP_ACCOUNT:-}"; return 1; }
  spl_sql_proxy_start || return 1
  proxied=1
  dsn="$(spl_local_dsn "$cloud_dsn" "$SPL_PROXY_PORT")" || {
    spl_sql_proxy_stop
    do_log "FATAL the DSN in $SPL_DSN_SECRET is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"
    return 1
  }
}

# spl_tenant_create_host <tenant> (SPL-959): the new tenant's WUI host, when
# this env's cnf serves tenant hosts; a no-op otherwise, or with TENANT_HOST=0.
# The cnf edit, its push and the apply are all do_spl_tenant_host_provision's.
spl_tenant_create_host() {
  local t="$1" cnf on
  [[ "${TENANT_HOST:-1}" == 1 ]] || { do_log "INFO TENANT_HOST=0: no tenant host for $t"; return 0; }
  cnf="$(spl_th_cnf_file)" || return 1
  on="$(yq -r '.env.steps."019-firebase-static-site".wui_tenant_hosts // false' "$cnf")"
  [[ "$on" == true ]] || { do_log "INFO wui_tenant_hosts is off in $ENV: $t gets no host (the apex serves it)"; return 0; }
  TENANT_ID="$t" DRY_RUN=0 do_spl_tenant_host_provision
}

# spl_tenant_create_pin_wui <tenant> <url> <pub> <priv> <tmp dir> (SPL-1290):
# pin box-wui under the new tenant through do_spl_cloud_pin_box_wui, its root
# key in a 0600 file under the caller's private tmp dir (removed with it).
# A subshell, so the pin action's RETURN trap cannot replace the caller's.
spl_tenant_create_pin_wui() {
  local t="$1" url="$2" pub="$3" priv="$4" dir="$5" f
  [[ "${TENANT_PIN_WUI:-1}" == 1 ]] || { do_log "INFO TENANT_PIN_WUI=0: box-wui is not pinned under $t"; return 0; }
  f="$dir/tenant.json"
  ( umask 077 && printf '{"tenant":"%s","url":"%s","root_pubkey":"%s","root_private_key":"%s"}\n' \
      "$t" "$url" "$pub" "$priv" >"$f" ) || return 1
  ( TENANT_ID="$t" TENANT_FILE="$f" DRY_RUN=0 FORCE=0 do_spl_cloud_pin_box_wui ) >/dev/null
  local rc=$?
  rm -f "$f"
  (( rc == 0 )) && do_log "OK box-wui pinned under $t (SPL-1290): its people's posts reach the agents"
  return $rc
}
