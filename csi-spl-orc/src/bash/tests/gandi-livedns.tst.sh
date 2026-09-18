#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: public DNS writes go through Gandi LiveDNS (007 T014 follow-up).
#   1. bash -n on the gandi lib + actions
#   2. no product domain literal, no shop leftovers, no GCP NS in @example
#   3. _gandi_domain: DOMAIN env, else cnf env.dns.BASE_DOMAIN; empty fails
#   4. set-nameservers refuses ns-cloud-* and never PUTs (even CONFIRM=yes)
#   5. set-dns-record refuses apex @ A; dry-runs * A; CONFIRM=yes PUTs * A
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

LIB="$PROJ_ROOT/lib/bash/funcs/gandi-api.func.sh"
SET_NS="$PROJ_ROOT/src/bash/run/gandi-set-nameservers.func.sh"
SET_RR="$PROJ_ROOT/src/bash/run/gandi-set-dns-record.func.sh"
GET_NS="$PROJ_ROOT/src/bash/run/gandi-get-nameservers.func.sh"
LIST_RR="$PROJ_ROOT/src/bash/run/gandi-list-dns-records.func.sh"
LIST_DOM="$PROJ_ROOT/src/bash/run/gandi-list-domains.func.sh"
CHECK="$PROJ_ROOT/src/bash/run/gandi-check-creds.func.sh"
CNF_ALL="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"

for f in "$LIB" "$SET_NS" "$SET_RR" "$GET_NS" "$LIST_RR" "$LIST_DOM" "$CHECK"; do
  [[ -f "$f" ]] || { echo "FAIL: not found: $f"; exit 1; }
  bash -n "$f" && pass "bash -n $(basename "$f")" || fail "bash -n $(basename "$f")"
done

grep -qiE 'wordpress|recaptcha|brevo|improvmx|stripe' "$PROJ_ROOT"/src/bash/run/gandi-*.func.sh "$LIB" \
  && fail "gandi actions still carry shop entities" || pass "gandi actions have no shop entities"

for banned in 'spool-hub.ai' 'lukamotor.es' 'ns-cloud-e1.googledomains.com'; do
  if grep -nF "$banned" "$LIB" "$PROJ_ROOT"/src/bash/run/gandi-*.func.sh; then
    fail "banned token in gandi sources: $banned"
  else
    pass "no '$banned' in gandi sources"
  fi
done
if grep -A2 '@example' "$SET_NS" | grep -qiE 'ns-cloud-|googledomains'; then
  fail "gandi-set-nameservers @example still targets GCP NS"
else
  pass "gandi-set-nameservers @example does not target GCP NS"
fi
grep -q 'ns-cloud-' "$SET_NS" && grep -q 'googledomains.com' "$SET_NS" \
  && pass "gandi-set-nameservers refuses GCP NS by name" \
  || fail "gandi-set-nameservers is missing the GCP NS refuse"

want=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$CNF_ALL")
[[ -n "$want" && "$want" == *.* ]] || { fail "could not read env.dns.BASE_DOMAIN from cnf"; want=""; }
got=$(
  APP_PATH="$APP_ROOT" bash -c '
    do_log(){ echo "$*" >&2; }
    source "'"$LIB"'"
    _gandi_domain
  '
)
if [[ -n "$want" && "$got" == "$want" ]]; then
  pass "_gandi_domain returns cnf env.dns.BASE_DOMAIN"
else
  fail "_gandi_domain returned '${got:-<empty>}'"
fi

got=$(
  APP_PATH="$APP_ROOT" DOMAIN=override.example.test bash -c '
    do_log(){ echo "$*" >&2; }
    source "'"$LIB"'"
    _gandi_domain
  '
)
[[ "$got" == "override.example.test" ]] && pass "DOMAIN env overrides cnf" \
  || fail "DOMAIN override got '${got:-<empty>}'"

tmp=$(mktemp -d)
mkdir -p "$tmp/csi-spl-cnf/csi-spl"
printf 'env:\n  dns:\n    BASE_DOMAIN: ""\n' >"$tmp/csi-spl-cnf/csi-spl/all.env.yaml"
printf 'env:\n  ORG: csi\n  dns:\n    env_subdomain: dev\n' >"$tmp/csi-spl-cnf/csi-spl/dev.env.yaml"
if APP_PATH="$tmp" bash -c '
    do_log(){ echo "$*" >&2; }
    source "'"$LIB"'"
    _gandi_domain
  ' >/dev/null 2>&1; then
  fail "empty BASE_DOMAIN was accepted"
else
  pass "empty BASE_DOMAIN is an error"
fi

printf 'env:\n  dns:\n    BASE_DOMAIN: example.test\n' >"$tmp/csi-spl-cnf/csi-spl/all.env.yaml"

run_gandi() {
  local api_log="$1" fn="$2"; shift 2
  env APP_PATH="$tmp" HOME="$tmp" ORG=csi GANDI_PAT=tok GANDI_TOKEN="" API_LOG="$api_log" \
      LIB="$LIB" SET_NS="$SET_NS" SET_RR="$SET_RR" GANDI_FN="$fn" "$@" \
  bash -c '
    do_log(){ echo "$*"; }
    source "$LIB"
    source "$SET_RR"
    source "$SET_NS"
    _gandi_api(){ echo "API $*" >> "$API_LOG"; echo "[]"; }
    "$GANDI_FN"
  '
}

api=$(mktemp)
out=$(run_gandi "$api" do_gandi_set_nameservers CONFIRM=yes \
      NAMESERVERS=ns-cloud-x1.googledomains.com,ns-cloud-x2.googledomains.com 2>&1) || true
if echo "$out" | grep -q 'refusing GCP Cloud DNS' && [[ ! -s "$api" ]]; then
  pass "set-nameservers refuses ns-cloud-* and does not call the API"
else
  fail "set-nameservers did not refuse GCP NS (out=$out api=$(cat "$api"))"
fi

api=$(mktemp)
out=$(run_gandi "$api" do_gandi_set_nameservers CONFIRM=yes \
      NAMESERVERS=ns-101-a.gandi.net,ns-102-b.gandi.net 2>&1) || true
if echo "$out" | grep -q 'dry-run only' && [[ ! -s "$api" ]]; then
  pass "set-nameservers never PUTs even with CONFIRM=yes"
else
  fail "set-nameservers applied or did not dry-run (out=$out api=$(cat "$api"))"
fi

api=$(mktemp)
out=$(run_gandi "$api" do_gandi_set_dns_record CONFIRM=yes \
      RRSET_NAME=@ RRSET_TYPE=A RRSET_VALUES=192.0.2.10 2>&1) || true
if echo "$out" | grep -q 'refusing to change' && [[ ! -s "$api" ]]; then
  pass "set-dns-record refuses apex @ A (Gandi parking)"
else
  fail "set-dns-record allowed apex @ A (out=$out)"
fi

api=$(mktemp)
out=$(run_gandi "$api" do_gandi_set_dns_record \
      RRSET_NAME='*' RRSET_TYPE=A RRSET_VALUES=192.0.2.10 2>&1) || true
if echo "$out" | grep -q 'dry-run' && [[ ! -s "$api" ]]; then
  pass "set-dns-record dry-runs * A without CONFIRM=yes"
else
  fail "set-dns-record * A dry-run leaked an API call (out=$out)"
fi

api=$(mktemp)
out=$(run_gandi "$api" do_gandi_set_dns_record CONFIRM=yes \
      RRSET_NAME='*' RRSET_TYPE=A RRSET_VALUES=192.0.2.10 2>&1) || true
if grep -q 'API PUT /livedns/domains/example.test/records/\*/A' "$api"; then
  pass "CONFIRM=yes set-dns-record * A calls LiveDNS PUT"
else
  fail "CONFIRM=yes did not PUT * A (api=$(cat "$api") out=$out)"
fi

rm -rf "$tmp"
rm -f "$api"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
