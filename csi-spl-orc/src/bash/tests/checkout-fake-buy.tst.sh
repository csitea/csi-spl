#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_checkout_fake_buy (006 T020/T021) buys a tenant on the fake
#          rail against a REAL `spool serve` + a throwaway Postgres: the tenant
#          is unknown before fake-pay and resolves after, the key is claimed
#          once into a 0600 file and never printed, a second claim is 410, and
#          the hub logs the claim-link mail but never the key.
#          CONTROLS: ENV=prd is refused; a hub with fake-pay OFF is refused
#          (rail none); buying the same slug again fails; DRY_RUN buys nothing.
#          Postgres: local server binaries or a CACHED docker image (never
#          pulled); with neither the live part SKIPs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
PG_CTR="" HUB_PID="" HUB2_PID=""
cleanup() {
  [[ -n "$HUB_PID" ]] && kill "$HUB_PID" 2>/dev/null
  [[ -n "$HUB2_PID" ]] && kill "$HUB2_PID" 2>/dev/null
  [[ -n "$PG_CTR" ]] && docker rm -f "$PG_CTR" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" LDE_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_checkout_fake_buy'
}

FUNC="$PROJ_ROOT/src/bash/run/spl-checkout-fake-buy.func.sh"
domain=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")
[[ -n "$domain" ]] && ! grep -qF "$domain" "$FUNC" && pass "action source has no $domain literal" || fail "action bakes $domain"

in_orc ENV=prd TENANT_ID=acme BUYER_EMAIL=buyer@example.com DRY_RUN=0 BASE_URL=http://127.0.0.1:1 >"$T/prd.out" 2>&1 \
  && fail "CONTROL ENV=prd was not refused" || { grep -q "fake-pay does not exist on prd" "$T/prd.out" && pass "CONTROL ENV=prd refused" || fail "prd: $(cat "$T/prd.out")"; }
in_orc ENV=lde TENANT_ID=acme DRY_RUN=0 BASE_URL=http://127.0.0.1:1 >/dev/null 2>&1 \
  && fail "missing BUYER_EMAIL accepted" || pass "missing BUYER_EMAIL refused"

# --- live: throwaway Postgres + spool serve ------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no cached $PG_IMAGE image; live buy not run"
  [[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions (live part skipped)"; exit 0; }
  exit 1
fi
export PATH=/usr/local/go/bin:$PATH GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-fake-buy-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | head -1 | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }

serve() { # <port> <fake:true|false> <log>
  mkdir -p "$T/files-$1"
  SPOOL_HUB_ENV=lde SPOOL_HUB_DB_DSN="$DSN" SPOOL_HUB_FILES_DIR="$T/files-$1" SPOOL_HUB_TENANT_HOST_PATTERN='{tenant}.lde.localhost' \
    SPOOL_HUB_LISTEN_ADDR="127.0.0.1:$1" SPOOL_HUB_ENABLE_FAKE_PAY="$2" SPOOL_HUB_PAYMENT_PLAN_CENTS=2000 \
    SPOOL_HUB_PAYMENT_PUBLIC_SCHEME=http SPOOL_HUB_PAYMENT_CLAIM_URL=http://localhost:3000/checkout/claim \
    SPOOL_HUB_MAIL_TRANSPORT=log "$BIN" serve >"$3" 2>&1 &
}
P1=$((30000 + RANDOM % 15000)); P2=$((P1 + 1))
serve "$P1" true "$T/hub.log"; HUB_PID=$!
serve "$P2" false "$T/hub2.log"; HUB2_PID=$!
for p in "$P1" "$P2"; do for _ in $(seq 1 50); do curl -fs "127.0.0.1:$p/healthz" >/dev/null && break; sleep 0.2; done; done

in_orc ENV=lde TENANT_ID=acme BUYER_EMAIL=buyer@example.com BASE_URL="http://127.0.0.1:$P2" DRY_RUN=0 >/dev/null 2>"$T/off.err" \
  && fail "CONTROL a hub with fake-pay off was not refused" \
  || { grep -q "rail is 'none'" "$T/off.err" && pass "CONTROL fake-pay off: refused (rail none)" || fail "off: $(cat "$T/off.err")"; }

in_orc ENV=lde TENANT_ID=acme BUYER_EMAIL=buyer@example.com BASE_URL="http://127.0.0.1:$P1" >"$T/dry.out" 2>/dev/null \
  && jq -e '.dry_run == true and .rail == "fake"' "$T/dry.out" >/dev/null && pass "DRY_RUN reads the plan only" || fail "dry: $(cat "$T/dry.out")"
curl -s -H 'Host: acme.lde.localhost' "127.0.0.1:$P1/v1/view/threads" | grep -q unknown_tenant \
  && pass "DRY_RUN bought nothing (acme still unknown)" || fail "DRY_RUN created acme"

KEY="$T/keys/acme.json"
if in_orc ENV=lde TENANT_ID=acme BUYER_EMAIL=buyer@example.com BASE_URL="http://127.0.0.1:$P1" DRY_RUN=0 KEY_OUT="$KEY" TENANT_HOST_SUFFIX=lde.localhost >"$T/buy.out" 2>"$T/buy.err"; then
  pass "fake buy completed: $(cat "$T/buy.out")"
else
  fail "fake buy: $(cat "$T/buy.err")"
fi
jq -e '.tenant_before == 404 and .status == "paid" and .claim == 200 and .claim_again == 410 and .tenant_after != 404 and .key_b64_len == 88' \
  "$T/buy.out" >/dev/null && pass "unknown before, paid, claimed once (410 after), tenant resolves after" || fail "summary: $(cat "$T/buy.out")"
[[ "$(stat -c %a "$KEY" 2>/dev/null)" == 600 ]] && pass "key file is 0600" || fail "key file mode: $(stat -c %a "$KEY" 2>&1)"
key=$(jq -r .root_private_key "$KEY" 2>/dev/null)
[[ ${#key} -eq 88 ]] && ! grep -qF "$key" "$T/buy.out" "$T/buy.err" "$T/hub.log" \
  && pass "the root key is in the file only (not stdout, not do_log, not the hub log)" || fail "key leaked or missing"
grep -q '"template":"tenant_paid"' "$T/hub.log" && pass "the hub logged the one claim-link mail (log transport)" || fail "no tenant_paid in the hub log"
in_orc ENV=lde TENANT_ID=acme BUYER_EMAIL=buyer@example.com BASE_URL="http://127.0.0.1:$P1" DRY_RUN=0 KEY_OUT="$T/keys/again.json" TENANT_HOST_SUFFIX=lde.localhost >/dev/null 2>"$T/again.err" \
  && fail "CONTROL buying acme twice succeeded" \
  || { grep -q "HTTP 409" "$T/again.err" && pass "CONTROL a second buy of acme is 409" || fail "again: $(cat "$T/again.err")"; }

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
