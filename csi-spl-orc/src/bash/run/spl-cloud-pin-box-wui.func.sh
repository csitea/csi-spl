#!/bin/bash
#------------------------------------------------------------------------------
# @description dev/prd: pin the hub's box-wui key under one tenant (spec 014
# @description T022, contracts/wui-dispatch.md section 2.2), the cloud twin of
# @description do_spl_pin_box_wui (lde). box-wui's restricted role keys off the
# @description reserved box id (spec 014 FR: kind task|note only), so the pin
# @description is all a tenant needs.
# @description   1. GET https://<tenant>.<fqdn>/v1/wui/pubkey (404 = 030 does
# @description      not inject the key yet: hub.wui_key.inject)
# @description   2. `spool hub-pin --box box-wui --pubkey <b64> --root-key <f>`
# @description      (POST /v1/pins signed by the tenant root key; the hub
# @description      accepts only its own loaded key). --force only with FORCE=1
# @description      (after a key rotation).
# @description   3. CONTROL: the same pin with a foreign key must be refused
# @description      400 wui_key_mismatch, proving the hub checks the key.
# @description The root key comes from TENANT_FILE, the 0600 JSON that
# @description do_spl_tenant_create's output was saved to (root_private_key),
# @description copied into a 0600 scratch file and shredded. Prints only
# @description public values. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - the tenant slug
# @param TENANT_FILE - the tenant's saved create JSON (0600)
# @param FORCE (optional) - 1: replace a different existing box-wui pin
# @param DRY_RUN (optional) - 1 (default): GET the pubkey only. 0: pin.
# @param SPOOL_BIN (optional) - spool CLI; otherwise built from csi-spl-api
# @example ENV=dev TENANT_ID=t1 TENANT_FILE=<path> DRY_RUN=0 ./run -a do_spl_cloud_pin_box_wui
#------------------------------------------------------------------------------
do_spl_cloud_pin_box_wui() {
  do_require_bin curl yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" tf="${TENANT_FILE:-}" box=box-wui
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID '$tenant' is not a tenant slug"; return 1; }
  [[ -s "$tf" ]] || { do_log "FATAL TENANT_FILE must name the tenant's saved create JSON (got '$tf')"; return 1; }
  [[ "$(stat -c %a "$tf")" == 600 ]] || { do_log "FATAL $tf must be mode 0600"; return 1; }

  # specs/026: the API host; the tenant is named by SPOOL_TENANT (X-Spool-Tenant)
  local url body code pub
  url="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ "$url" != "https://" ]] || { do_log "FATAL env.dns.api_fqdn is empty in $SPL_CNF"; return 1; }
  body="$(curl -s -m 15 -w '\n%{http_code}' "$url/v1/wui/pubkey")"
  code="${body##*$'\n'}" body="${body%$'\n'*}"
  [[ "$code" == 200 ]] || { do_log "FATAL GET $url/v1/wui/pubkey -> ${code:-none} $body (030 must inject the key: hub.wui_key.inject)"; return 1; }
  pub="$(yq -p json -r '.pubkey // ""' <<<"$body")"
  [[ "$pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { do_log "FATAL /v1/wui/pubkey returned no ed25519 pubkey: $body"; return 1; }
  if (( dry )); then
    printf '{"tenant":"%s","url":"%s","box_id":"%s","pubkey":"%s","dry_run":true}\n' "$tenant" "$url" "$box" "$pub"
    do_log "OK DRY_RUN would pin $box ($pub) under $tenant at $url"
    return 0
  fi

  local cli="${SPOOL_BIN:-}"
  if [[ -z "$cli" || ! -x "$cli" ]]; then
    spl_host_spool || return 1
    cli="$SPL_SPOOL"
  fi
  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h/root.key' 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  (umask 077 && python3 - "$tf" "$tenant" >"$h/root.key" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("tenant") != sys.argv[2]: sys.exit("tenant mismatch")
sys.stdout.write(d["root_private_key"] + "\n")
PY
  ) || { do_log "FATAL $tf holds no root_private_key for tenant $tenant"; return 1; }

  local force=() out
  [[ "${FORCE:-0}" == 1 ]] && force=(--force)
  _pin() {  # <pubkey> [--force]
    SPOOL_HUB_URL="$url" SPOOL_TENANT="$tenant" SPOOL_BOX_ID=box-operator SPOOL_ROOT="$h/spool" SPOOL_KEYS_DIR="$h/keys" \
      "$cli" hub-pin --box "$box" --pubkey "$1" --root-key "$h/root.key" "${@:2}" 2>&1
  }
  out="$(_pin "$pub" "${force[@]}")" || { unset -f _pin; do_log "FATAL hub-pin $box under $tenant: $out"; return 1; }

  # control: a key the hub does not hold is refused
  local foreign ctl
  foreign="$(python3 -c 'import base64,os; print(base64.b64encode(os.urandom(32)).decode())')"
  if ctl="$(_pin "$foreign" --force)"; then
    unset -f _pin; do_log "FATAL CONTROL: the hub accepted a foreign box-wui key ($ctl)"; return 1
  fi
  unset -f _pin
  [[ "$ctl" == *wui_key_mismatch* ]] || { do_log "FATAL CONTROL: foreign key refused, but not as wui_key_mismatch: $ctl"; return 1; }

  printf '{"tenant":"%s","url":"%s","box_id":"%s","pubkey":"%s","pinned":true,"control":"wui_key_mismatch"}\n' "$tenant" "$url" "$box" "$pub"
  do_log "OK pinned $box under $tenant ($url); control: a foreign key is refused wui_key_mismatch"
}
