#!/usr/bin/env bash
# verify-hub-endpoints.sh -- post-deploy smoke of the spool hub's PUBLIC
# acceptance endpoints for one env, over HTTPS, the way a client reaches them.
#
# Modelled on csi-rel's verify-api-health.sh: one script the workflow calls
# (22_deploy-verify.yml) and an operator can run by hand, retries per probe,
# FATAL/WARN mapped to ::error:: / ::warning:: so a verdict shows on the run page,
# and an UNKNOWN exit (2) for "could not see", which must not redden trunk.
#
# The endpoints (spec 008 FR-P12), derived from cnf -- the domain literal lives
# ONLY in csi-spl-cnf all.env.yaml env.dns.BASE_DOMAIN:
#   site  GET https://<env.dns.fqdn>/                          200, non-empty body
#   api   GET https://[<env_subdomain>.]api.<BASE_DOMAIN>/version
#         200 + JSON {version, commit, built_at}, each a non-empty string
#   (fqdn = <env_subdomain>.<BASE_DOMAIN>, or BASE_DOMAIN when env_subdomain
#    is empty: prd serves the apex.)
#
# Per probe, the LAST attempt decides:
#   ok       200 and the body is right
#   pending  the endpoint is not reachable YET, not broken:
#              dns     the name does not resolve       (curl exit 6)
#              cert    TLS handshake / cert rejected   (curl exit 35, 51, 58, 60)
#                      -- a Google-managed cert that is not ACTIVE yet
#              refused nothing listens on 443 at that address (curl exit 7):
#                      the name does not point at the hub's LB yet (e.g. the
#                      apex still on registrar parking). A Google LB accepts
#                      the connection even when its backend is down.
#              ingress HTTP 403 -- the 031 Cloud Armor allowlist refused this
#                      client (a GitHub runner is not on it)
#   fail     anything else: 5xx, 404, a 200 with a wrong body, a timeout
#
# Exit: 0 every probe ok; 1 any probe failed; 2 no failure but >= 1 pending
# (UNKNOWN: the deploy STANDS but is not proven end to end).
#
# Env in:
#   ENV_NAME         required -- dev | prd
#   VERIFY_ATTEMPTS  optional -- attempts per probe (default 6)
#   VERIFY_DELAY     optional -- seconds between attempts (default 10)
#   VERIFY_ENDPOINTS optional -- override the cnf-derived list, one probe per
#                    line: "<site|api> <url>" (tests, or a one-off host)
#   APP_PATH         optional -- repo root (default: derived from this file)
set -uo pipefail

: "${ENV_NAME:?ENV_NAME must be set (dev | prd)}"
ATTEMPTS="${VERIFY_ATTEMPTS:-6}"
DELAY="${VERIFY_DELAY:-10}"
ROOT_DIR="${APP_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"

gh_err()  { echo "::error::$*"; }
gh_warn() { echo "::warning::$*"; }

# --- the endpoint list: from cnf, unless overridden ---------------------------
endpoints="${VERIFY_ENDPOINTS:-}"
if [[ -z "$endpoints" ]]; then
  cnf_out="$(ENV="$ENV_NAME" APP_PATH="$ROOT_DIR" PROJ_PATH="$ROOT_DIR/csi-spl-orc" \
      SPL_STATE_DIR="$(mktemp -d)" bash -c '
    set -euo pipefail
    do_log() { echo "$*" >&2; }
    source "$APP_PATH/csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_spl_cloud_cnf
    echo "$SPL_FQDN"
    yq -r ".env.dns.BASE_DOMAIN // \"\"" "$SPL_CNF"
    yq -r ".env.dns.env_subdomain // \"\"" "$SPL_CNF"')" \
    || { gh_err "verify-hub-endpoints: cannot resolve the $ENV_NAME cnf"; exit 1; }
  { read -r fqdn; read -r base; read -r sub; } <<<"$cnf_out"
  [[ -n "$fqdn" && -n "$base" && "$fqdn" != null && "$base" != null ]] \
    || { gh_err "verify-hub-endpoints: env.dns.fqdn / BASE_DOMAIN empty for $ENV_NAME"; exit 1; }
  [[ "$sub" == null ]] && sub=""
  endpoints="site https://${fqdn}/
api https://${sub:+${sub}.}api.${base}/version"
fi

# --- one probe ----------------------------------------------------------------
# probe <kind> <url> -> prints "ok|pending:<why>|fail:<why>"
probe() {
  local kind="$1" url="$2" body code rc
  body="$(mktemp)"
  code="$(curl -sS --max-time 15 -o "$body" -w '%{http_code}' "$url" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) ;;
    6)              rm -f "$body"; echo "pending:dns (name does not resolve)"; return ;;
    7)              rm -f "$body"; echo "pending:refused (nothing on 443 there -- the name does not point at the hub LB yet)"; return ;;
    35|51|58|60)    rm -f "$body"; echo "pending:cert (TLS rejected, curl $rc -- managed cert not ACTIVE yet?)"; return ;;
    *)              rm -f "$body"; echo "fail:curl exit $rc (http ${code:-000})"; return ;;
  esac
  case "$code" in
    200) ;;
    403) rm -f "$body"; echo "pending:ingress (HTTP 403 -- the LB allowlist refused this client)"; return ;;
    *)   rm -f "$body"; echo "fail:HTTP $code"; return ;;
  esac
  if [[ "$kind" == api ]]; then
    if jq -e 'type == "object" and ([.version, .commit, .built_at] | all(type == "string" and length > 0))' \
         "$body" >/dev/null 2>&1; then
      echo "ok $(jq -c '{version, commit, built_at}' "$body")"
    else
      echo "fail:200 but not {version,commit,built_at}: $(head -c 120 "$body" | tr '\n' ' ')"
    fi
  else
    [[ -s "$body" ]] && echo "ok ($(wc -c <"$body") bytes)" || echo "fail:200 with an empty body"
  fi
  rm -f "$body"
}

# --- run every probe, retrying until ok or out of attempts --------------------
n_ok=0 n_pending=0 n_fail=0
summary=""
while read -r kind url; do
  [[ -n "${kind:-}" ]] || continue
  verdict=""
  for ((i = 1; i <= ATTEMPTS; i++)); do
    verdict="$(probe "$kind" "$url")"
    echo "$ENV_NAME $kind $url attempt $i/$ATTEMPTS: $verdict"
    [[ "$verdict" == ok* ]] && break
    (( i < ATTEMPTS )) && sleep "$DELAY"
  done
  case "$verdict" in
    ok*)      n_ok=$((n_ok + 1)) ;;
    pending*) n_pending=$((n_pending + 1)); gh_warn "$ENV_NAME $kind $url NOT PROVEN -- ${verdict#pending:}" ;;
    *)        n_fail=$((n_fail + 1));       gh_err  "$ENV_NAME $kind $url FAILED -- ${verdict#fail:}" ;;
  esac
  summary+="| \`$kind\` | $url | ${verdict} |"$'\n'
done <<<"$endpoints"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "## Deploy verify: spool hub -> $ENV_NAME"; echo
    echo "| probe | url | verdict |"; echo "|---|---|---|"; printf '%s' "$summary"; } >>"$GITHUB_STEP_SUMMARY"
fi

echo "$ENV_NAME verify: ok=$n_ok pending=$n_pending fail=$n_fail"
(( n_fail > 0 )) && exit 1
(( n_pending > 0 )) && exit 2
exit 0
