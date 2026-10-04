#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_self_host_up (spec 072 A2) preflights before `up`, writes a
#          mode-600 .env whose passwords survive a re-run, calls
#          `docker compose up -d --wait` and prints the owner link. By CALLING
#          it with stubbed dig / nc / docker and a stubbed SMTP login, against
#          a temp dir holding a docker-compose.yml: no network, no real Docker.
#          CONTROL: a wrong A record fails before `up` (up is never called).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

S="$T/stack"; mkdir -p "$S" "$T/stub"
echo 'name: spool' >"$S/docker-compose.yml"
IP=203.0.113.7
# dig: the A record is $DIG_A; nc: busy when the port is in $NC_BUSY;
# docker: every call logged, `compose ps` lists web when $PS_WEB=1, no
# compose plugin when $NO_COMPOSE=1
cat >"$T/stub/dig" <<'SH'
#!/bin/sh
echo "dig $*" >>"$STUB_LOG"; [ -n "${DIG_A:-}" ] && echo "$DIG_A"; exit 0
SH
cat >"$T/stub/nc" <<'SH'
#!/bin/sh
echo "nc $*" >>"$STUB_LOG"; for p in ${NC_BUSY:-}; do [ "$p" = "$5" ] && exit 0; done; exit 1
SH
cat >"$T/stub/docker" <<'SH'
#!/bin/sh
echo "docker $*" >>"$STUB_LOG"
case "$*" in "compose version") [ "${NO_COMPOSE:-0}" = 1 ] && exit 1 ;; *" ps "*) [ "${PS_WEB:-0}" = 1 ] && echo web ;; esac
exit 0
SH
chmod +x "$T/stub/"*

run_up() {  # [VAR=value ...] -> the action's output; calls in $T/calls.log
  : >"$T/calls.log"
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" STUB_LOG="$T/calls.log" PATH="$T/stub:$PATH" \
      SPOOL_SELF_HOST_DIR="$S" SPOOL_PUBLIC_IP="$IP" DIG_A="$IP" \
      SPOOL_DOMAIN=chat.example.com SPOOL_OWNER_EMAIL=owner@example.com \
      SPOOL_MAIL_SMTP_HOST=smtp.example.com SPOOL_MAIL_SMTP_USER=relay SPOOL_MAIL_SMTP_PASSWORD=good-pw \
      "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_self_host_smtp_login() { echo "smtp $* user=$SMTP_USER" >>"$STUB_LOG"; [ "$SMTP_PASSWORD" = good-pw ]; }
    do_spl_self_host_up' </dev/null 2>&1
}
ups() { grep -c ' up -d --wait' "$T/calls.log"; }

# --- all preflights pass -> up is called, the link is printed ----------------
out=$(run_up); rc=$?
[[ $rc -eq 0 && $(ups) -eq 1 ]] && pass "all preflights pass: docker compose up -d --wait is called once" || fail "pass run: rc=$rc ups=$(ups) $out"
grep -qF "OWNER LINK: https://chat.example.com/login?tenant=main" <<<"$out" && pass "the owner link is printed" || fail "no owner link: $out"
grep -q "up -d --wait" "$T/calls.log" && grep -q -- "--project-directory $S" "$T/calls.log" && pass "up runs in the stack dir" || fail "up call: $(cat "$T/calls.log")"
[[ $(grep -c 'PREFLIGHT ok' <<<"$out") -eq 5 ]] && pass "five preflights reported ok (docker, A record, 80, 443, SMTP)" || fail "preflight lines: $out"
[[ "$(stat -c %a "$S/.env")" == 600 ]] && pass ".env is mode 600" || fail ".env mode $(stat -c %a "$S/.env")"
grep -qx "SPOOL_PUBLIC_URL='https://chat.example.com'" "$S/.env" && grep -qx "SPOOL_HUB_ENV='prd'" "$S/.env" \
  && grep -qx "SPOOL_MAIL_FROM='spool@chat.example.com'" "$S/.env" && pass ".env carries the own-domain profile" || fail ".env: $(cat "$S/.env")"
pw1=$(grep -E '^SPOOL_DB_(OWNER|RUNTIME|SUPERUSER)_PASSWORD=' "$S/.env")
[[ $(grep -cE "='[0-9a-f]{48}'$" <<<"$pw1") -eq 3 && $(sort -u <<<"$pw1" | sed 's/.*=//' | sort -u | wc -l) -eq 3 ]] \
  && pass "three distinct generated 48-hex Postgres passwords" || fail "passwords: $pw1"
if grep -qF "${pw1##*=}" <<<"$out" || grep -qF good-pw <<<"$out" || grep -qF good-pw "$T/calls.log"; then
  fail "a secret appears in the output or an argv"; else pass "no secret in the output or any argv"; fi

# --- a re-run keeps the secrets (and a hand-set key), web holds its ports ----
echo "SPOOL_TENANT=acme" >>"$S/.env"
out=$(run_up PS_WEB=1 NC_BUSY="80 443"); rc=$?
pw2=$(grep -E '^SPOOL_DB_(OWNER|RUNTIME|SUPERUSER)_PASSWORD=' "$S/.env")
[[ $rc -eq 0 && "$pw1" == "$pw2" ]] && pass "a re-run keeps the three passwords" || fail "re-run: rc=$rc $out"
[[ $(grep -c "kept from the existing .env" <<<"$out") -eq 3 ]] && pass "a re-run says each password was kept" || fail "kept lines: $out"
grep -qx "SPOOL_TENANT=acme" "$S/.env" && grep -qF "login?tenant=acme" <<<"$out" && pass "a hand-set key survives and names the tenant in the link" || fail "tenant: $out"
[[ "$(stat -c %a "$S/.env")" == 600 ]] && pass ".env still mode 600 after the re-run" || fail "re-run mode"
grep -q "port 80 (held by this stack" <<<"$out" && pass "a re-run accepts 80/443 held by its own web container" || fail "own ports: $out"

# --- answers come from .env on a re-run: no env var, no tty ------------------
out=$(run_up SPOOL_DOMAIN= SPOOL_OWNER_EMAIL= SPOOL_MAIL_SMTP_HOST= SPOOL_MAIL_SMTP_USER= SPOOL_MAIL_SMTP_PASSWORD= PS_WEB=1); rc=$?
[[ $rc -eq 0 && $(ups) -eq 1 ]] && pass "a re-run with no answers given reads them from .env" || fail "env answers: rc=$rc $out"

# --- CONTROL: a wrong A record fails before up -------------------------------
cp -p "$S/.env" "$T/env.before"
out=$(run_up DIG_A=198.51.100.9); rc=$?
[[ $rc -ne 0 && $(ups) -eq 0 ]] && pass "CONTROL: a wrong A record fails and up is never called" || fail "CONTROL: rc=$rc ups=$(ups) $out"
grep -q "PREFLIGHT FAIL the A record of chat.example.com is 198.51.100.9" <<<"$out" && grep -q "fix: point the A record" <<<"$out" \
  && pass "the A-record failure names its fix" || fail "A fix line: $out"
cmp -s "$S/.env" "$T/env.before" && pass "a failed preflight leaves .env untouched" || fail ".env changed on a failed preflight"

# --- each other failure names its fix and stops before up --------------------
check_fail() {  # <label> <expected fix fragment> [VAR=value ...]
  local label="$1" fix="$2"; shift 2
  out=$(run_up "$@"); rc=$?
  [[ $rc -ne 0 && $(ups) -eq 0 ]] && grep -q "fix: .*$fix" <<<"$out" \
    && pass "$label: fails before up, names its fix" || fail "$label: rc=$rc ups=$(ups) $out"
}
check_fail "no A record" "add an A record" DIG_A=
check_fail "port 443 busy" "stop what listens on it" NC_BUSY=443
check_fail "SMTP login refused" "check the host, port, user and password" SPOOL_MAIL_SMTP_PASSWORD=bad-pw
check_fail "no compose plugin" "install the docker-compose-plugin" NO_COMPOSE=1
out=$(run_up NC_BUSY=80 DIG_A=198.51.100.9)
grep -q "PREFLIGHT FAIL port 80" <<<"$out" && grep -q "PREFLIGHT FAIL the A record" <<<"$out" && grep -q "FATAL 2 preflight" <<<"$out" && pass "every preflight runs: a port failure is still reported alongside another" || fail "not all checks ran"

out=$(run_up SPOOL_DOMAIN=https://chat.example.com/); rc=$?
[[ $rc -ne 0 ]] && grep -q "not a bare domain" <<<"$out" && pass "a URL as the domain is refused" || fail "url domain: $out"

echo
if (( fails )); then echo "self-host-up: $fails FAIL"; exit 1; fi
echo "self-host-up: all PASS"
