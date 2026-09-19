#!/bin/bash
#------------------------------------------------------------------------------
# @description lde: pin the hub's box-wui key under a tenant (spec 014
# @description contracts/wui-dispatch.md §2.2), so WUI dispatch reaches boxes.
# @description   1. GET http://<tenant>.localhost:<hub port>/v1/wui/pubkey
# @description      (404 = the hub has no box-wui key: run the stack with
# @description      LDE_WUI_DISPATCH=1)
# @description   2. `spool hub-pin --box box-wui --pubkey <b64> --root-key
# @description      <tenant root key> --force` (--force: the lde key is
# @description      ephemeral, a hub restart mints a new one; re-run this)
# @description   3. proof: the pins row for (tenant, box-wui) is live and holds
# @description      exactly that key
# @description LOCAL ONLY. Needs the stack from do_setup_app_inf, whose smoke
# @description tenant's root key it uses by default. Prints the pubkey, never
# @description a private key.
# @param TENANT_ID (optional) - default cnf env.lde.smoke_tenant
# @param ROOT_KEY (optional) - the tenant root private key file; default the
# @param   smoke tenant's, $LDE_STATE_DIR/hello/root.key (other tenants: required)
# @param SPOOL_BIN (optional) - spool CLI; default the host build do_setup_app_inf made
# @example LDE_WUI_DISPATCH=1 ./run -a do_setup_app_inf && ./run -a do_spl_pin_box_wui
# @example TENANT_ID=acme ROOT_KEY=/path/to/acme-root.key ./run -a do_spl_pin_box_wui
#------------------------------------------------------------------------------
do_spl_pin_box_wui() {
  do_require_bin curl yq || return 1
  do_lde_cnf || return 1
  local tenant="${TENANT_ID:-$LDE_SMOKE_TENANT}" box=box-wui
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID '$tenant' is not a tenant slug"; return 1; }
  local root_key="${ROOT_KEY:-}"
  if [[ -z "$root_key" ]]; then
    [[ "$tenant" == "$LDE_SMOKE_TENANT" ]] || { do_log "FATAL ROOT_KEY is required for tenant $tenant (no default outside the smoke tenant)"; return 1; }
    root_key="$LDE_STATE_DIR/hello/root.key"
  fi
  [[ -s "$root_key" ]] || { do_log "FATAL no tenant root key at $root_key (run ./run -a do_setup_app_inf first)"; return 1; }
  local cli="${SPOOL_BIN:-$LDE_STATE_DIR/bin/spool}"
  [[ -x "$cli" ]] || { do_log "FATAL no spool CLI at $cli (run ./run -a do_setup_app_inf first)"; return 1; }

  local host="$tenant.localhost" url body code pub
  url="http://$host:$LDE_HUB_PORT"
  body="$(curl -s -m 10 -w '\n%{http_code}' --resolve "$host:$LDE_HUB_PORT:127.0.0.1" "$url/v1/wui/pubkey")"
  code="${body##*$'\n'}" body="${body%$'\n'*}"
  case "$code" in
    200) ;;
    404) do_log "FATAL GET $url/v1/wui/pubkey -> 404 $body; turn dispatch on: LDE_WUI_DISPATCH=1 ./run -a do_setup_app_inf"; return 1 ;;
    *) do_log "FATAL GET $url/v1/wui/pubkey -> ${code:-none} $body (is the lde hub up?)"; return 1 ;;
  esac
  pub="$(yq -p json -r '.pubkey // ""' <<<"$body")"
  [[ "$pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { do_log "FATAL /v1/wui/pubkey returned no ed25519 pubkey: $body"; return 1; }

  local h="$LDE_STATE_DIR/pin-box-wui" out
  mkdir -p "$h" && chmod 700 "$h" || return 1
  out="$(SPOOL_HUB_URL="$url" SPOOL_BOX_ID=box-smoke SPOOL_ROOT="$h/spool" SPOOL_KEYS_DIR="$h/keys" \
    "$cli" hub-pin --box "$box" --pubkey "$pub" --root-key "$root_key" --force 2>&1)" ||
    { do_log "FATAL hub-pin $box under $tenant: $out"; return 1; }

  local row
  row="$(lde_compose exec -T pg psql -U "$LDE_PG_USER" -d "$LDE_PG_DB" -Atc \
    "select encode(pubkey, 'base64') from pins where tenant_id = '$tenant' and box_id = '$box' and revoked_at is null" 2>&1)"
  [[ "$row" == "$pub" ]] || { do_log "FATAL hub-pin said ok but the pins row reads '$row', want $pub"; return 1; }
  printf '{"tenant":"%s","box_id":"%s","pubkey":"%s","dispatch":%s,"pinned":true}\n' \
    "$tenant" "$box" "$pub" "$(yq -p json -r '.dispatch' <<<"$body")"
  do_log "OK pinned $box under $tenant ($url); the pins row holds the hub's key. A hub restart mints a new ephemeral key: re-run this"
}
