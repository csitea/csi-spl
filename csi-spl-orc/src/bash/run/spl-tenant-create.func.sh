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
# @param SPOOL_HUB_DB_DSN - required when DRY_RUN=0 (cloud: the Secret Manager DSN; lde: derived)
# @param SPOOL_BIN (optional) - spool CLI; otherwise built from csi-spl-api
# @example TENANT_ID=acme ./run -a do_spl_tenant_create --json
# @example ENV=lde DRY_RUN=0 TENANT_ID=acme ./run -a do_spl_tenant_create --json
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

  if [[ "$dry" == 1 ]]; then
    do_log "INFO DRY_RUN would INSERT tenant $tenant (pubkey only, billing_status=manual) and print the root private key once"
    printf '{"tenant":"%s","url":"%s","billing_status":"manual","dry_run":true,"would":"generate root keypair; INSERT tenants root_pubkey only"}\n' \
      "$tenant" "$url"
    do_log "OK DRY_RUN tenant $tenant url=$url (no key generated, nothing inserted)"
    return 0
  fi

  [[ -n "$dsn" ]] || {
    do_log "FATAL SPOOL_HUB_DB_DSN is required when DRY_RUN=0 (cloud: the Secret Manager DSN; lde: derived)"
    return 1
  }

  local cli="${SPOOL_BIN:-}"
  if [[ -z "$cli" || ! -x "$cli" ]]; then
    local out="${LDE_STATE_DIR:-${SPL_STATE_DIR:-/tmp}}/bin/spool"
    mkdir -p "$(dirname "$out")" || return 1
    bash "$APP_PATH/csi-spl-api/src/bash/build.sh" "$out" >/dev/null || {
      do_log "FATAL spool build failed"
      return 1
    }
    cli="$out"
  fi

  local tmp pub priv
  tmp="$(mktemp -d)" || return 1
  chmod 700 "$tmp" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

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
}
