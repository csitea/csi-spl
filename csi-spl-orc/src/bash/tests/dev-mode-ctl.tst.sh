#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: local dev mode up / down (spec 148 row B6, SPL-4026):
# do_dev_mode_up, do_dev_mode_down and do_dev_mode_ctl drive the root compose
# file's dev profile. Hermetic: docker is a stub on PATH that logs its argv
# and the dev variables it was handed, the preflight is a stub script.
#   1. up: preflight first, on the four ports the stack publishes, then
#      compose --profile dev up -d --build --wait with the dev defaults
#      (lde, smtp to Mailpit, TLS none, dev login on, the dev toolbar, the
#      raised form limit, image tag local)
#   2. a value in the checkout's .env wins over the default, the shell's over
#      both (the port list and the sender follow it)
#   3. a running stack: the preflight checks no port (they are its own)
#   4. DEV_MODE_BUILD=0: no --build, no image tag set
#   5. down: --remove-orphans; --purge and DEV_MODE_PURGE=1 add -v
#   6. status: ps -a
#   CONTROLS:
#     a. a failing preflight (check 7) -> rc 7, compose up never runs
#     b. SPOOL_HUB_ENV=prd (shell) or dev (.env) -> rc 1, nothing runs
#     c. compose up fails -> its rc and a FATAL line, no "is up"
#     d. no docker-compose.yml, an unknown DEV_MODE_CMD -> rc 1
#   7. ./run registers all three actions (the loader derives one action per
#      file name, so up and down each need their own file)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for f in dev-mode-ctl dev-mode-up dev-mode-down; do
  [[ -f "$PROJ_ROOT/src/bash/run/$f.func.sh" ]] || { echo "FAIL: no $f.func.sh"; exit 1; }
done

mkdir -p "$T/bin"
cat >"$T/bin/docker" <<'D'
#!/usr/bin/env bash
echo "ARGS $*" >>"$DOCKER_LOG"
for v in SPOOL_HUB_ENV SPOOL_AUTH_DEV_LOGIN_ENABLED SPOOL_MAIL_TRANSPORT SPOOL_MAIL_SMTP_HOST \
  SPOOL_MAIL_SMTP_PORT SPOOL_MAIL_SMTP_TLS SPOOL_MAIL_FROM SPOOL_ENV_NAME SPOOL_AUTH_FORM_PER_IP SPOOL_AUTH_DEBUG_LINKS SPOOL_IMAGE_TAG; do
  echo "ENV $v=${!v-<unset>}" >>"$DOCKER_LOG"
done
case " $* " in
  *" ps -q --status running "*) echo "${DOCKER_RUNNING:-}" ;;
  *" up "*) exit "${DOCKER_UP_RC:-0}" ;;
esac
D
cat >"$T/preflight" <<'P'
#!/usr/bin/env bash
echo "PREFLIGHT ports=[${DEV_PREFLIGHT_PORTS-<unset>}]" >>"$DOCKER_LOG"
exit "${PREFLIGHT_RC:-0}"
P
chmod +x "$T/bin/docker" "$T/preflight"

tree() {  # <dir> [.env line...]: a checkout holding the compose file
  rm -rf "$1"; mkdir -p "$1"; touch "$1/docker-compose.yml"
  local d="$1"; shift
  (($#)) && printf '%s\n' "$@" >"$d/.env"
  return 0
}
act() {  # <action> <tree> [env...] -- [args]: runs it, OUT + RC; log in $T/d.log
  local fn="$1" tr="$2"; shift 2
  local envs=() args=()
  while (($#)) && [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == -- ]] && shift; args=("$@")
  : >"$T/d.log"
  OUT=$(env PATH="$T/bin:$PATH" DOCKER_LOG="$T/d.log" PROJ_PATH="$PROJ_ROOT" APP_PATH="$tr" \
    DEV_MODE_PREFLIGHT="$T/preflight" "${envs[@]}" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in dev-mode-ctl dev-mode-up dev-mode-down; do source "$PROJ_PATH/src/bash/run/$f.func.sh"; done
    '"$fn"' "$@"' _ "${args[@]}" 2>&1)
  RC=$?
}
has() { grep -qxF -- "$1" "$T/d.log"; }
up_line() { grep -m1 '^ARGS .* up ' "$T/d.log"; }

# --- 1. up ------------------------------------------------------------------------
tree "$T/w"
act do_dev_mode_up "$T/w"
first=$(sed -n 1,2p "$T/d.log" | grep -c -e '^PREFLIGHT' -e 'ps -q')
want="ARGS compose --project-directory $T/w -f $T/w/docker-compose.yml --profile dev up -d --build --wait --wait-timeout 900"
[[ $RC == 0 ]] && has "PREFLIGHT ports=[8080 8443 1025 8025]" && [[ "$(up_line)" == "$want" ]] &&
  [[ $(grep -n '^PREFLIGHT' "$T/d.log" | cut -d: -f1) -lt $(grep -n ' up ' "$T/d.log" | cut -d: -f1) ]] &&
  pass "1. up: preflight on the 4 published ports, then compose up --build --wait" ||
  fail "1. rc $RC first=$first: $OUT / $(cat "$T/d.log")"
ok=1
for kv in SPOOL_HUB_ENV=lde SPOOL_AUTH_DEV_LOGIN_ENABLED=true SPOOL_MAIL_TRANSPORT=smtp SPOOL_MAIL_SMTP_HOST=mail \
  SPOOL_MAIL_SMTP_PORT=1025 SPOOL_MAIL_SMTP_TLS=none SPOOL_MAIL_FROM=spool@example.org SPOOL_ENV_NAME=lde \
  SPOOL_AUTH_FORM_PER_IP=100 SPOOL_AUTH_DEBUG_LINKS=false SPOOL_IMAGE_TAG=local; do
  sed -n '/ up /,$p' "$T/d.log" | grep -xF "ENV $kv" >/dev/null || { ok=0; fail "1. compose up lacks $kv"; }
done
((ok)) && pass "1. compose up gets every dev default and image tag local"
grep -q '^OK local dev mode is up' <<<"$OUT" && grep -q 'http://localhost:8025' <<<"$OUT" &&
  pass "1. prints the app and the Mailpit inbox" || fail "1. output: $OUT"

# --- 2. .env and shell override ---------------------------------------------------
tree "$T/w" SPOOL_HTTP_PORT=18080 SPOOL_MAILPIT_UI_PORT=18025 SPOOL_MAIL_FROM=dev@example.com SPOOL_MAIL_SMTP_TLS=starttls
act do_dev_mode_up "$T/w"
[[ $RC == 0 ]] && has "PREFLIGHT ports=[18080 8443 1025 18025]" && has "ENV SPOOL_MAIL_FROM=dev@example.com" &&
  has "ENV SPOOL_MAIL_SMTP_TLS=starttls" && grep -q 'http://localhost:18080' <<<"$OUT" &&
  pass "2. the checkout's .env wins over the defaults" || fail "2. rc $RC: $(cat "$T/d.log")"
act do_dev_mode_up "$T/w" SPOOL_MAIL_FROM=shell@example.com SPOOL_HTTP_PORT=28080
has "ENV SPOOL_MAIL_FROM=shell@example.com" && has "PREFLIGHT ports=[28080 8443 1025 18025]" &&
  pass "2. the shell wins over .env" || fail "2. shell: $(cat "$T/d.log")"

# --- 3. running stack ---------------------------------------------------------------
tree "$T/w"
act do_dev_mode_up "$T/w" DOCKER_RUNNING=abc123
[[ $RC == 0 ]] && has "PREFLIGHT ports=[ ]" && up_line >/dev/null &&
  pass "3. a running stack: no port is checked, up still runs" || fail "3. rc $RC: $(cat "$T/d.log")"

# --- 4. no build --------------------------------------------------------------------
act do_dev_mode_up "$T/w" DEV_MODE_BUILD=0
[[ $RC == 0 && "$(up_line)" != *--build* ]] && sed -n '/ up /,$p' "$T/d.log" | grep -xF "ENV SPOOL_IMAGE_TAG=<unset>" >/dev/null &&
  pass "4. DEV_MODE_BUILD=0: no --build, no image tag" || fail "4. rc $RC: $(cat "$T/d.log")"

# --- 5. down ------------------------------------------------------------------------
base="ARGS compose --project-directory $T/w -f $T/w/docker-compose.yml --profile dev"
act do_dev_mode_down "$T/w"
[[ $RC == 0 ]] && has "$base down --remove-orphans" && ! grep -q PREFLIGHT "$T/d.log" &&
  pass "5. down: --remove-orphans, no preflight" || fail "5. rc $RC: $(cat "$T/d.log")"
act do_dev_mode_down "$T/w" -- --purge
has "$base down --remove-orphans -v" && pass "5. down --purge adds -v" || fail "5. --purge: $(cat "$T/d.log")"
act do_dev_mode_down "$T/w" DEV_MODE_PURGE=1
has "$base down --remove-orphans -v" && pass "5. DEV_MODE_PURGE=1 adds -v" || fail "5. PURGE=1: $(cat "$T/d.log")"

# --- 6. status ----------------------------------------------------------------------
act do_dev_mode_ctl "$T/w"
[[ $RC == 0 ]] && has "$base ps -a" && pass "6. status (the default): ps -a" || fail "6. rc $RC: $(cat "$T/d.log")"

# --- CONTROLS -----------------------------------------------------------------------
act do_dev_mode_up "$T/w" PREFLIGHT_RC=7
[[ $RC == 7 ]] && ! up_line >/dev/null && grep -q 'FATAL dev preflight check 7' <<<"$OUT" &&
  pass "a. a failing preflight: rc 7, compose up never runs" || fail "a. rc $RC: $OUT / $(cat "$T/d.log")"
act do_dev_mode_up "$T/w" SPOOL_HUB_ENV=prd
[[ $RC == 1 ]] && [[ ! -s "$T/d.log" ]] && grep -q 'FATAL SPOOL_HUB_ENV=prd' <<<"$OUT" &&
  pass "b. SPOOL_HUB_ENV=prd in the shell: refused, nothing runs" || fail "b. prd rc $RC: $OUT / $(cat "$T/d.log")"
tree "$T/w" SPOOL_HUB_ENV=dev
act do_dev_mode_up "$T/w"
[[ $RC == 1 ]] && [[ ! -s "$T/d.log" ]] && pass "b. SPOOL_HUB_ENV=dev in .env: refused, nothing runs" || fail "b. dev rc $RC: $OUT"
tree "$T/w"
act do_dev_mode_up "$T/w" DOCKER_UP_RC=17
[[ $RC == 17 ]] && grep -q 'FATAL docker compose up failed (17)' <<<"$OUT" && ! grep -q 'is up' <<<"$OUT" &&
  pass "c. compose up fails: its rc, FATAL, no 'is up'" || fail "c. rc $RC: $OUT"
act do_dev_mode_up "$T/nowhere"
[[ $RC == 1 && ! -s "$T/d.log" ]] && grep -q 'FATAL no docker-compose.yml' <<<"$OUT" &&
  pass "d. no compose file: rc 1, nothing runs" || fail "d. rc $RC: $OUT"
act do_dev_mode_ctl "$T/w" DEV_MODE_CMD=restart
[[ $RC == 1 ]] && grep -q "FATAL DEV_MODE_CMD 'restart'" <<<"$OUT" && pass "d. unknown DEV_MODE_CMD: rc 1" || fail "d. cmd rc $RC: $OUT"

# --- 7. ./run registers the actions -------------------------------------------------
for a in do_dev_mode_up do_dev_mode_down do_dev_mode_ctl; do
  : >"$T/d.log"
  out=$(cd "$PROJ_ROOT" && env PATH="$T/bin:$PATH" DOCKER_LOG="$T/d.log" DEV_MODE_TREE="$T/w" \
    DEV_MODE_PREFLIGHT="$T/preflight" ./run -a "$a" 2>&1); rc=$?
  [[ $rc == 0 ]] && grep -q '^ARGS compose ' "$T/d.log" && ! grep -q 'NOT found' <<<"$out" &&
    pass "7. ./run -a $a runs" || fail "7. ./run -a $a rc $rc: $(tail -5 <<<"$out")"
done

echo
[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
