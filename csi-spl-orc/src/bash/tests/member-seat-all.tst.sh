#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_member_seat_all (SPL-2126) seats one person in every listed
#          workspace and every live channel there through the named actions.
#          gcloud and psql are stubbed; the three write actions are stubbed to
#          a log, so an absent call is absent.
#   0. the action parses; its SQL heredoc is not shell-expanded and is a
#      READ ONLY transaction that writes nothing.
#   1. bad input is refused before any gcloud or psql call.
#   2. an EMAIL with no human yet is pending: exit 3, no write action called.
#   3. a non-member is added with the role, a member with another role gets
#      the role action (FROM_ROLE), a member with the role is left alone; every
#      listed channel gets one channel add; the values travel as psql -v.
#   4. two humans for one email, or a HUMAN_ID missing from humans: refused.
#   5. WATCH=1 repeats while pending and stops once seated, or gives up at
#      WATCH_UNTIL with exit 3.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "FAIL: no yq"; exit 1; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/state"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud|$*" >>"$STUB_LOG"
case "$*" in
  "auth activate-service-account"*) for a; do [[ "$a" == --key-file=* ]] && jq -r .client_email "${a#*=}" >"$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) echo "postgres://spool_hub:pw@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
EOF
# psql: one call per tenant; prints the stub file for that tenant.
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
cat >>"$T_STDIN"
t=""; for a; do [[ "$a" == tenant=* ]] && t="${a#tenant=}"; done
cat "$STUB_DIR/$t" 2>/dev/null
exit 0
EOF
for b in cloud-sql-proxy docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u HUMAN_ID -u EMAIL -u TENANT_ID \
    -u TENANT_IDS -u MEMBER_ROLE -u ORDERED_BY -u WATCH -u WATCH_INTERVAL -u WATCH_UNTIL -u CHANNEL \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" STUB_DIR="$T/db" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    do_spl_tenant_member_add() { echo "ACT member_add t=$TENANT_ID h=$HUMAN_ID e=${EMAIL:-} r=$MEMBER_ROLE d=${DRY_RUN:-1} c=${CREATE_HUMAN:-}" >>"$STUB_LOG"; }
    do_spl_tenant_member_role() { echo "ACT member_role t=$TENANT_ID h=$HUMAN_ID r=$MEMBER_ROLE from=$FROM_ROLE d=${DRY_RUN:-1}" >>"$STUB_LOG"; }
    do_spl_channel_member_add() { echo "ACT chan_add t=$TENANT_ID c=$CHANNEL h=$HUMAN_ID e=${EMAIL:-} d=${DRY_RUN:-1}" >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}
acts() { grep -c '^ACT' "$T/calls.log" || true; }

FUNC="$PROJ_ROOT/src/bash/run/spl-member-seat-all.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
sqlbody=$(awk 'index($0, "<<'\''SQL'\''") {p=1; next} $0=="SQL" {p=0} p' "$FUNC")
[[ -n "$sqlbody" ]] && ! grep -q '\$' <<<"$sqlbody" \
  && grep -qx 'BEGIN READ ONLY;' <<<"$sqlbody" \
  && grep -qx "SET LOCAL app.tenant_id = :'tenant';" <<<"$sqlbody" \
  && ! grep -qiE '\b(insert|update|delete|drop|truncate|alter)\b' <<<"$sqlbody" \
  && pass "0. the SQL is one READ ONLY transaction per tenant, no shell expansion, no write" \
  || fail "0. the SQL heredoc: $sqlbody"

# --- 1. bad input -------------------------------------------------------------
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_member_seat_all' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. $label refused before any call" || fail "1. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "missing TENANT_IDS" HUMAN_ID=HUM-4 MEMBER_ROLE=developer
refuse "bad tenant slug" TENANT_IDS='acme T_1' HUMAN_ID=HUM-4 MEMBER_ROLE=developer
refuse "neither HUMAN_ID nor EMAIL" TENANT_IDS=acme MEMBER_ROLE=developer
refuse "both HUMAN_ID and EMAIL" TENANT_IDS=acme HUMAN_ID=HUM-4 EMAIL=a@example.com MEMBER_ROLE=developer
refuse "bad HUMAN_ID" TENANT_IDS=acme "HUMAN_ID=HUM-4' or '1'='1" MEMBER_ROLE=developer
refuse "bad EMAIL" TENANT_IDS=acme EMAIL=nope MEMBER_ROLE=developer
refuse "missing MEMBER_ROLE" TENANT_IDS=acme HUMAN_ID=HUM-4
refuse "DRY_RUN=2" TENANT_IDS=acme HUMAN_ID=HUM-4 MEMBER_ROLE=developer DRY_RUN=2
refuse "DRY_RUN=0 without ORDERED_BY" TENANT_IDS=acme HUMAN_ID=HUM-4 MEMBER_ROLE=developer DRY_RUN=0

# --- 2. pending ---------------------------------------------------------------
mkdir -p "$T/db"
printf 'human | none\nmember | acme | -\nchan | acme | general-talk\n' >"$T/db/acme"
in_orc 'do_spl_member_seat_all' TENANT_IDS=acme EMAIL=Person@Example.com MEMBER_ROLE=admin ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -eq 3 && "$(acts)" == 0 ]] && grep -q 'pending: no human signed in' "$T/out" \
  && grep -q '\[email=person@example.com\]' "$T/calls.log" \
  && pass "2. an email with no human yet: exit 3, nothing written" \
  || fail "2. pending: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 3. seat ------------------------------------------------------------------
printf 'human | HUM-7\nmember | acme | -\nchan | acme | design\nchan | acme | ops\n' >"$T/db/acme"
printf 'human | HUM-7\nmember | demo | developer\nchan | demo | public\n' >"$T/db/demo"
printf 'human | HUM-7\nmember | demo2 | regular_user\n' >"$T/db/demo2"
in_orc 'do_spl_member_seat_all' TENANT_IDS='acme demo demo2' HUMAN_ID=HUM-7 MEMBER_ROLE=developer ORDERED_BY=HUM-10 DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(acts)" == 5 ]] \
  && grep -qx 'ACT member_add t=acme h=HUM-7 e= r=developer d=0 c=0' "$T/calls.log" \
  && grep -qx 'ACT chan_add t=acme c=design h=HUM-7 e= d=0' "$T/calls.log" \
  && grep -qx 'ACT chan_add t=acme c=ops h=HUM-7 e= d=0' "$T/calls.log" \
  && grep -qx 'ACT chan_add t=demo c=public h=HUM-7 e= d=0' "$T/calls.log" \
  && grep -qx 'ACT member_role t=demo2 h=HUM-7 r=developer from=regular_user d=0' "$T/calls.log" \
  && ! grep -q 'member_add t=demo ' "$T/calls.log" \
  && grep -q 'OK HUM-7 is already a developer of demo' "$T/out" \
  && grep -q '\[tenant=demo2\]' "$T/calls.log" && grep -q '\[human=HUM-7\]' "$T/calls.log" \
  && ! grep -q 'HUM-7' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && pass "3. add, role change, already-seated and one add per channel, values as -v" \
  || fail "3. seat: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

in_orc 'do_spl_member_seat_all' TENANT_IDS=acme HUMAN_ID=HUM-7 MEMBER_ROLE=developer; rc=$?
[[ $rc -eq 0 && "$(acts)" == 3 ]] && ! grep -q ' d=0' "$T/calls.log" \
  && pass "3. DRY_RUN (default) reaches every write action as its own dry run" \
  || fail "3. dry: rc=$rc $(cat "$T/calls.log")"

# --- 4. refusals --------------------------------------------------------------
printf 'human | many:2\nmember | acme | -\n' >"$T/db/acme"
in_orc 'do_spl_member_seat_all' TENANT_IDS=acme EMAIL=p@example.com MEMBER_ROLE=admin; rc=$?
[[ $rc -eq 1 && "$(acts)" == 0 ]] && grep -q 'matches 2 humans' "$T/out" \
  && pass "4. two humans for one email: refused" || fail "4. many: rc=$rc $(cat "$T/out")"
printf 'human | missing\nmember | acme | -\n' >"$T/db/acme"
in_orc 'do_spl_member_seat_all' TENANT_IDS=acme HUMAN_ID=HUM-9 MEMBER_ROLE=admin; rc=$?
[[ $rc -eq 1 && "$(acts)" == 0 ]] && grep -q 'FATAL human HUM-9 is not in humans' "$T/out" \
  && pass "4. a missing HUMAN_ID: refused" || fail "4. missing: rc=$rc $(cat "$T/out")"

# --- 5. WATCH -----------------------------------------------------------------
in_orc 'n=0; _spl_member_seat_all_pass() { n=$((n+1)); echo "pass $n" >>"$STUB_LOG"; (( n < 3 )) && return 3; return 0; }
  sleep() { echo "sleep $1" >>"$STUB_LOG"; }; do_spl_member_seat_all' \
  TENANT_IDS=acme EMAIL=p@example.com MEMBER_ROLE=admin WATCH=1 WATCH_INTERVAL=7; rc=$?
[[ $rc -eq 0 ]] && [[ "$(grep -c '^pass' "$T/calls.log")" == 3 && "$(grep -c '^sleep 7$' "$T/calls.log")" == 2 ]] \
  && pass "5. WATCH=1 repeats every WATCH_INTERVAL while pending and stops once seated" \
  || fail "5. watch: rc=$rc $(cat "$T/calls.log")"
in_orc '_spl_member_seat_all_pass() { echo pass >>"$STUB_LOG"; return 3; }; sleep() { echo sleep >>"$STUB_LOG"; }; do_spl_member_seat_all' \
  TENANT_IDS=acme EMAIL=p@example.com MEMBER_ROLE=admin WATCH=1 WATCH_INTERVAL=60 WATCH_UNTIL='+10 seconds'; rc=$?
[[ $rc -eq 3 ]] && [[ "$(grep -c '^pass' "$T/calls.log")" == 1 ]] && ! grep -q sleep "$T/calls.log" \
  && grep -q 'gave up' "$T/out" \
  && pass "5. WATCH gives up at WATCH_UNTIL with exit 3" || fail "5. until: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
in_orc 'do_spl_member_seat_all' TENANT_IDS=acme HUMAN_ID=HUM-7 MEMBER_ROLE=admin WATCH=1 WATCH_INTERVAL=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "5. WATCH_INTERVAL=0 refused before any call" || fail "5. interval: rc=$rc $(cat "$T/out")"

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
