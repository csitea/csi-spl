#!/bin/bash
#------------------------------------------------------------------------------
# spl_hub_operator_call — CLE-77780: call the hub's operator invite surface
# (/v1/operator/*) from the box, so the HUB on Cloud Run creates the invite and
# sends its mail from GCP. No box ever dials SMTP (the home IPv6 egress that
# timed out for 70 s). The box authenticates as the pinned env service account
# (do_gcp_pin_account: its key, never the owner account) with a Google id token
# minted for the hub's own URL; the hub checks that audience and the SA email
# against SPOOL_HUB_OPERATOR_AUDIENCE / SPOOL_HUB_OPERATOR_EMAILS.
#------------------------------------------------------------------------------

# spl_hub_operator_url — set SPL_HUB_URL to the env's hub API origin
# (https://<env.dns.api_fqdn>): the audience the box mints the id token for and
# the host it calls. Needs do_spl_cloud_cnf (SPL_CNF) to have run.
spl_hub_operator_url() {
  [[ -n "${SPL_CNF:-}" ]] || { do_log "FATAL SPL_CNF is empty (do_spl_cloud_cnf did not run)"; return 1; }
  SPL_HUB_URL="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ "$SPL_HUB_URL" != https:// ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF: no hub URL for the operator route"; return 1; }
  export SPL_HUB_URL
}

# spl_hub_operator_call <METHOD> <PATH> [JSON_BODY]
# Preconditions: do_spl_cloud_cnf (SPL_HUB_URL, SPL_STATE_DIR) and
# do_gcp_pin_account (GCP_ACCOUNT, a private CLOUDSDK_CONFIG) have run.
# On success sets SPL_HUB_OP_STATUS (the HTTP code) and SPL_HUB_OP_BODY (the
# response body) and returns 0 even for an HTTP 4xx/5xx — the caller reads the
# code. Returns non-zero only when no token could be minted or no HTTP response
# came back. The id token never rides argv (a -K config file, 0600), like the
# relay password never did.
spl_hub_operator_call() {
  local method="$1" path="$2" body="${3:-}"
  [[ -n "${SPL_HUB_URL:-}" ]] || { do_log "FATAL SPL_HUB_URL is empty (do_spl_cloud_cnf did not run)"; return 1; }
  [[ -n "${GCP_ACCOUNT:-}" ]] || { do_log "FATAL GCP_ACCOUNT is empty (do_gcp_pin_account did not run)"; return 1; }
  [[ -n "${SPL_STATE_DIR:-}" ]] || { do_log "FATAL SPL_STATE_DIR is empty"; return 1; }
  local tok
  tok="$(gcloud auth print-identity-token --audiences="$SPL_HUB_URL" --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$tok" ]] || { do_log "FATAL could not mint an id token as $GCP_ACCOUNT for audience $SPL_HUB_URL"; return 1; }
  local hdr="$SPL_STATE_DIR/hub-op.hdr" out="$SPL_STATE_DIR/hub-op.body" code
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$hdr"; )
  local -a args=(-sS -m 30 -o "$out" -w '%{http_code}' -K "$hdr" -X "$method")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data "$body")
  code="$(curl "${args[@]}" "$SPL_HUB_URL$path" 2>/dev/null)"
  local rc=$?
  rm -f "$hdr"
  if (( rc != 0 )) || [[ -z "$code" ]]; then
    do_log "FATAL no HTTP response from $SPL_HUB_URL$path (as $GCP_ACCOUNT)"
    rm -f "$out"
    return 1
  fi
  SPL_HUB_OP_STATUS="$code"
  SPL_HUB_OP_BODY="$(cat "$out" 2>/dev/null)"
  rm -f "$out"
  return 0
}

# spl_hub_operator_json <k1> <v1> [<k2> <v2> ...] — build a JSON object from
# string key/value pairs, each value JSON-escaped (jq --arg), skipping empty
# values. Used to compose the operator route body without hand-escaping.
spl_hub_operator_json() {
  local -a jqargs=() keys=()
  local i=1
  while (( $# )); do
    local k="$1" v="${2:-}"; shift 2 || shift
    [[ -n "$v" ]] || continue
    jqargs+=(--arg "k$i" "$k" --arg "v$i" "$v")
    keys+=("(.[\$k$i]=\$v$i)")
    i=$((i + 1))
  done
  local prog='{}'
  local part
  for part in "${keys[@]}"; do prog="$prog | $part"; done
  jq -cn "${jqargs[@]}" "$prog"
}
