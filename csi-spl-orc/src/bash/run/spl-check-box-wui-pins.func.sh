#!/bin/bash
#------------------------------------------------------------------------------
# @description List every workspace of the env's hub whose box-wui pin is
# @description missing, revoked or not the hub's own key (SPL-1290). Without
# @description that pin the hub cannot sign a browser post for box-wui, so it
# @description stores the post UNSIGNED and fans it out to no box: the people
# @description of that workspace post, and no agent ever receives it.
# @description Measured on prd 2026-10-01 (CLE-77876): csitea had no box-wui
# @description pin since its creation, 128 human channel posts from 2026-09-29
# @description reached no agent; pas-psf the same. The fix for one workspace is
# @description do_spl_cloud_pin_box_wui (the tenant root key signs the pin).
# @description Prints one markdown row per workspace: the pin state and how
# @description many human channel posts the hub stored unsigned in the last
# @description PINS_DAYS days. Exit 1 when any row is a GAP.
# @description Read-only: GET /v1/wui/pubkey, and one READ ONLY transaction in
# @description operator RLS scope as the env SA.
# @param ENV - required: dev or prd
# @param PINS_DAYS (optional) - the unsigned-post look-back, default 7
# @param PINS_ROWS_FILE (optional) - rows instead of the hub DB, one per line:
# @param   <tenant>|<box-wui pubkey b64 or empty>|<revoked or empty>|<unsigned count>
# @param BOX_WUI_PUBKEY (optional) - the hub's key instead of GET /v1/wui/pubkey
# @example ENV=prd ./run -a do_spl_check_box_wui_pins
#------------------------------------------------------------------------------
do_spl_check_box_wui_pins() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local tmp hub rc=0
  tmp="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; trap - RETURN" RETURN
  if [[ -n "${PINS_ROWS_FILE:-}" ]]; then
    [[ -f "$PINS_ROWS_FILE" ]] || { do_log "FATAL no $PINS_ROWS_FILE"; return 1; }
    cp "$PINS_ROWS_FILE" "$tmp/rows"
  else
    do_require_bin yq psql curl || return 1
    do_spl_cloud_cnf || return 1
    do_gcp_pin_account "$SPL_CNF" || return 1
    do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
    spl_via_proxy _spl_box_wui_pins_read "$tmp/rows" ||
      { do_log "FATAL could not read the box-wui pins of $ENV"; return 1; }
  fi
  hub="${BOX_WUI_PUBKEY:-}"
  [[ -n "$hub" ]] || hub="$(spl_hub_wui_pubkey)" || return 1
  spl_box_wui_pins_table "$hub" <"$tmp/rows" || rc=1
  return $rc
}

# The hub's box-wui public key (b64), from GET <api>/v1/wui/pubkey.
spl_hub_wui_pubkey() {
  local url body pub
  url="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ "$url" != "https://" ]] || { do_log "FATAL env.dns.api_fqdn is empty in $SPL_CNF"; return 1; }
  body="$(curl -s -m 15 -f "$url/v1/wui/pubkey")" || { do_log "FATAL GET $url/v1/wui/pubkey failed"; return 1; }
  pub="$(yq -p json -r '.pubkey // ""' <<<"$body")"
  [[ "$pub" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { do_log "FATAL /v1/wui/pubkey returned no ed25519 pubkey: $body"; return 1; }
  echo "$pub"
}

# Read-only, inside spl_via_proxy: one row per tenant (see PINS_ROWS_FILE).
_spl_box_wui_pins_read() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F '|' -v ON_ERROR_STOP=1 -v days="${PINS_DAYS:-7}" >"$1" <<'SQL'
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT t.tenant_id,
       coalesce(encode(p.pubkey, 'base64'), ''),
       CASE WHEN p.revoked_at IS NOT NULL THEN 'revoked' ELSE '' END,
       (SELECT count(*) FROM messages m
         WHERE m.tenant_id = t.tenant_id AND m.from_box = 'box-wui' AND m.env_sig = ''
           AND m.channel IS NOT NULL AND m.from_id LIKE 'HUM-%'
           AND m.received_at > now() - make_interval(days => :days))
  FROM tenants t
  LEFT JOIN pins p ON p.tenant_id = t.tenant_id AND p.box_id = 'box-wui'
 ORDER BY 1;
COMMIT;
SQL
}

# spl_box_wui_pins_table <hub pubkey>: rows on stdin -> the table; 1 on a GAP.
spl_box_wui_pins_table() {
  local hub="$1" t pin rev uns v gaps=0 n=0
  echo "| workspace | box-wui pin | unsigned human posts (${PINS_DAYS:-7} d) | verdict |"
  echo "|---|---|---|---|"
  while IFS='|' read -r t pin rev uns; do
    [[ -n "$t" ]] || continue
    n=$((n + 1))
    if [[ -z "$pin" ]]; then v="GAP no pin: do_spl_cloud_pin_box_wui"; pin=none
    elif [[ -n "$rev" ]]; then v="GAP revoked: do_spl_cloud_pin_box_wui FORCE=1"; pin="${pin:0:8}... revoked"
    elif [[ "$pin" != "$hub" ]]; then v="GAP not the hub's key: do_spl_cloud_pin_box_wui FORCE=1"; pin="${pin:0:8}..."
    else v=ok; pin="${pin:0:8}..."; fi
    [[ "$v" == ok && "${uns:-0}" -gt 0 ]] && v="ok (the unsigned posts predate the pin)"
    [[ "$v" == GAP* ]] && gaps=$((gaps + 1))
    echo "| $t | $pin | ${uns:-0} | $v |"
  done
  echo
  echo "box-wui pins ($ENV, hub key ${hub:0:8}...): $n workspace(s), $gaps gap(s)"
  (( gaps == 0 ))
}
