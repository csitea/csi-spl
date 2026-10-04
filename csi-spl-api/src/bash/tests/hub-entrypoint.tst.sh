#!/usr/bin/env bash
# specs/047 W9 + W18: the standalone hub-init / serve rules that depend on
# whether the stack is public (csi-spl-api/src/docker/hub-entrypoint.sh),
# sourced with SPOOL_ENTRYPOINT_LIB=1 and run under sh with stub spool / psql.
#   1. is_local: loopback URL host AND loopback bind; anything else is public
#   2. W9: off localhost each public default DB password is refused by name
#   3. W18: off localhost the owner is seated by a one-time invite for
#      SPOOL_OWNER_EMAIL while the tenant has no member; no email = refused
#   4. serve: SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=auto -> true local, false public
#   5. specs/072 A21: on Cloud Run (K_SERVICE) and in lde (SPOOL_ENTRYPOINT_PLAIN)
#      serve is plain `spool serve`; a bucket drops the image's files-dir default
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EP="$HERE/../../docker/hub-entrypoint.sh"
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/spool" <<'STUB'
#!/bin/sh
echo "spool $* FILES_DIR=${SPOOL_HUB_FILES_DIR-unset} BOOTSTRAP=${SPOOL_HUB_AUTH_BOOTSTRAP_OWNER:-}" >>"$STUB_LOG"
STUB
cat >"$T/bin/psql" <<'STUB'
#!/bin/sh
cat >/dev/null; echo "${STUB_MEMBERS:-0}"
STUB
chmod +x "$T/bin/"*

# ep <snippet> [VAR=value...]: run the snippet with the entrypoint's functions
ep() {
  local snip="$1"; shift
  env -i PATH="$T/bin:/usr/bin:/bin" STUB_LOG="$T/log" SPOOL_ENTRYPOINT_LIB=1 "$@" \
    sh -c '. "$0"; '"$snip" "$EP" 2>&1
}

# --- 1. is_local ---------------------------------------------------------------
while read -r url bind want; do
  [ "$bind" = - ] && bind=""
  got=public; ep is_local SPOOL_PUBLIC_URL="$url" ${bind:+SPOOL_BIND=$bind} >/dev/null && got=local
  [ "$got" = "$want" ] && pass "1. $url bind=${bind:-default} -> $want" || fail "1. $url bind=${bind:-default}: got $got, want $want"
done <<'CASES'
http://localhost:8080 - local
http://localhost:8080 127.0.0.1 local
http://127.0.0.1:18478 - local
http://app.localhost:8080 - local
http://[::1]:8080 ::1 local
https://chat.example.org 0.0.0.0 public
https://chat.example.org 127.0.0.1 public
http://localhost:8080 0.0.0.0 public
http://localhost.example.org - public
http://127.example.org - public
CASES
ep is_local >/dev/null && pass "1. no URL, no bind (the compose defaults) -> local" || fail "1. the defaults read as public"

# --- 2. W9: default passwords off localhost -------------------------------------------
PUB=(SPOOL_PUBLIC_URL=https://chat.example.org SPOOL_BIND=0.0.0.0)
DEF=(SPOOL_OWNER_PASSWORD=spool-local-owner SPOOL_RUNTIME_PASSWORD=spool-local-runtime SPOOL_SUPERUSER_PASSWORD=spool-local-superuser)
OWN=(SPOOL_OWNER_PASSWORD=own-pw-4711 SPOOL_RUNTIME_PASSWORD=rt-pw-4712 SPOOL_SUPERUSER_PASSWORD=su-pw-4713)
out="$(ep refuse_default_passwords "${PUB[@]}" "${DEF[@]}")"; rc=$?
[ $rc -ne 0 ] && grep -q 'SPOOL_DB_OWNER_PASSWORD SPOOL_DB_RUNTIME_PASSWORD SPOOL_DB_SUPERUSER_PASSWORD' <<<"$out" &&
  pass "2. public + the three defaults: refused, each named" || fail "2. defaults: rc $rc $out"
for one in SPOOL_OWNER_PASSWORD=spool-local-owner SPOOL_RUNTIME_PASSWORD=spool-local-runtime SPOOL_SUPERUSER_PASSWORD=spool-local-superuser; do
  ep refuse_default_passwords "${PUB[@]}" "${OWN[@]}" "$one" >/dev/null && fail "2. public + $one was accepted" || pass "2. public + only $one default: refused"
done
ep refuse_default_passwords "${PUB[@]}" "${OWN[@]}" >/dev/null && pass "2. public + own passwords: accepted" || fail "2. own passwords refused"
grep -qE 'pw-471[123]|spool-local-' <<<"$(ep refuse_default_passwords "${PUB[@]}" "${OWN[@]}" SPOOL_RUNTIME_PASSWORD=spool-local-runtime)" &&
  fail "2. a refusal echoes a password" || pass "2. a refusal never echoes a password"
out="$(ep 'is_local || refuse_default_passwords; echo reached' "${DEF[@]}")"
grep -q reached <<<"$out" && pass "2. CONTROL: localhost keeps the defaults (the quick start)" || fail "2. localhost refused: $out"

# --- 3. W18: the owner invite --------------------------------------------------------------
BASE=(SPOOL_TENANT=main SPOOL_OWNER_DSN=postgres://x "${PUB[@]}")
: >"$T/log"
out="$(ep seat_owner "${BASE[@]}" SPOOL_OWNER_EMAIL=owner@example.org STUB_MEMBERS=0)"; rc=$?
[ $rc -eq 0 ] && grep -q '^spool hub-invite --tenant main --email owner@example.org --role biz_owner --ttl 168h --no-mail --db postgres://x' "$T/log" &&
  grep -q 'OWNER: open https://chat.example.org/login?tenant=main and sign up with owner@example.org' <<<"$out" &&
  pass "3. no member yet: a one-time biz_owner invite for SPOOL_OWNER_EMAIL, the sign-in link printed" || fail "3. invite: rc $rc $out $(cat "$T/log")"
: >"$T/log"
out="$(ep seat_owner "${BASE[@]}" STUB_MEMBERS=0)"; rc=$?
[ $rc -ne 0 ] && grep -q 'set SPOOL_OWNER_EMAIL' <<<"$out" && [ ! -s "$T/log" ] &&
  pass "3. no member and no SPOOL_OWNER_EMAIL: refused, nothing written" || fail "3. no email: rc $rc $out"
out="$(ep seat_owner "${BASE[@]}" SPOOL_OWNER_EMAIL=owner@example.org STUB_MEMBERS=1)"; rc=$?
[ $rc -eq 0 ] && [ ! -s "$T/log" ] && grep -q 'has 1 member' <<<"$out" &&
  pass "3. CONTROL: a seated tenant gets no new invite (a re-run never re-opens one)" || fail "3. seated: rc $rc $out $(cat "$T/log")"

# --- 4. serve: bootstrap owner -----------------------------------------------------------------
serve() { : >"$T/log"; ep do_serve SPOOL_HUB_AUTH_SESSION_KEY=k "$@" >/dev/null; sed -n 's/.*BOOTSTRAP=//p' "$T/log"; }
[ "$(serve SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=auto)" = true ] && pass "4. auto on localhost -> true" || fail "4. auto local: $(cat "$T/log")"
[ "$(serve SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=auto "${PUB[@]}")" = false ] && pass "4. auto on a public host -> false" || fail "4. auto public: $(cat "$T/log")"
[ "$(serve SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=false)" = false ] && pass "4. an explicit false stays false" || fail "4. explicit false"
[ "$(serve SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=true "${PUB[@]}")" = true ] && pass "4. an explicit true is honoured (with a WARN)" || fail "4. explicit true"

# --- 5. plain serve: Cloud Run and lde -------------------------------------------------------
IMG=(SPOOL_HUB_FILES_DIR=/var/lib/spool/files)
plain() { : >"$T/log"; ep run_serve "${IMG[@]}" "$@"; }
out="$(plain K_SERVICE=hub SPOOL_HUB_FILES_BUCKET=b)"; rc=$?
[ $rc -eq 0 ] && [ "$(cat "$T/log")" = "spool serve FILES_DIR=unset BOOTSTRAP=" ] &&
  pass "5. Cloud Run: plain spool serve, no session key needed, no auto owner, the bucket wins" || fail "5. Cloud Run: rc $rc $out $(cat "$T/log")"
out="$(plain SPOOL_ENTRYPOINT_PLAIN=1 SPOOL_HUB_FILES_BUCKET=b SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=true)"; rc=$?
[ $rc -eq 0 ] && [ "$(cat "$T/log")" = "spool serve FILES_DIR=unset BOOTSTRAP=true" ] &&
  pass "5. lde: plain spool serve, its own env as given" || fail "5. lde: rc $rc $out $(cat "$T/log")"
out="$(plain)"; rc=$?
[ $rc -ne 0 ] && grep -q 'no session key' <<<"$out" && [ ! -s "$T/log" ] &&
  pass "5. CONTROL: compose (no K_SERVICE) still needs the state-dir session key" || fail "5. compose: rc $rc $out $(cat "$T/log")"
plain SPOOL_HUB_AUTH_SESSION_KEY=k >/dev/null
grep -q 'FILES_DIR=/var/lib/spool/files' "$T/log" && pass "5. compose without a bucket keeps the image's files dir" || fail "5. compose files dir: $(cat "$T/log")"

[ "$fails" -eq 0 ] && { echo "ALL hub-entrypoint CHECKS PASSED"; exit 0; }
echo "FAILED hub-entrypoint: $fails"; exit 1
