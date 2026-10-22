#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: .env.example carries the local dev mode block (spec 148 B2, SPL-2862):
#   1. a "local dev mode" section names the dev profile, Mailpit and its inbox
#   2. it sends the hub's mail to Mailpit: transport smtp, host mail, port 1025,
#      no TLS, no login, and names Mailpit's host ports 1025 / 8025
#   3. it names the dev login switch and keeps SPOOL_HUB_ENV at lde (the hub
#      refuses the dev login and the default secrets on dev / prd)
#   4. every dev secret it names equals the docker-compose.yml default, so
#      the file never drifts from what the stack really runs with
#   5. nothing is active by default: every line of the file is a comment or
#      blank (a copied .env changes nothing until a line is uncommented)
#   6. placeholders only: no host but mail / localhost / example.org, no hex
#      key in the block
#   CONTROL: the block found is the dev one (it holds no own-domain value)
# Hermetic: reads two files, no docker, no network.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

ex="$APP_ROOT/.env.example"
dc="$APP_ROOT/docker-compose.yml"
[[ -f "$ex" && -f "$dc" ]] || { fail "no .env.example or docker-compose.yml in $APP_ROOT"; exit 1; }

# the dev block: from its "# --- local dev mode" header to the next "# ---" one
blk=$(awk '/^# --- local dev mode/{on=1; print; next} on && /^# ---/{exit} on' "$ex")

# has <line> - the block holds this exact (commented) line
has() { grep -qxF -- "$1" <<<"$blk"; }

# --- 1. the section ---------------------------------------------------------------
[[ -n "$blk" ]] && pass "a local dev mode section exists" || { fail "no '# --- local dev mode' section in .env.example"; exit 1; }
grep -q -- '--profile dev' <<<"$blk" && pass "it names the compose dev profile" || fail "the section does not name --profile dev"
grep -q 'Mailpit' <<<"$blk" && grep -q 'http://localhost:8025' <<<"$blk" \
  && pass "it names Mailpit and its inbox on localhost:8025" || fail "the section does not name Mailpit and http://localhost:8025"

# --- 2. mail goes to Mailpit -------------------------------------------------------
for l in SPOOL_MAIL_TRANSPORT=smtp SPOOL_MAIL_SMTP_HOST=mail SPOOL_MAIL_SMTP_PORT=1025 SPOOL_MAIL_SMTP_TLS=none \
         SPOOL_MAIL_SMTP_USER= SPOOL_MAILPIT_SMTP_PORT=1025 SPOOL_MAILPIT_UI_PORT=8025; do
  has "# $l" && pass "dev block: $l" || fail "dev block lacks '# $l'"
done
grep -qE '^# SPOOL_MAIL_FROM=[^@ ]+@example\.org$' <<<"$blk" && pass "dev block: SPOOL_MAIL_FROM is an example.org address" || fail "dev block: no SPOOL_MAIL_FROM=<x>@example.org"

# --- 3. dev login on, env stays lde ------------------------------------------------
has "# SPOOL_AUTH_DEV_LOGIN_ENABLED=true" && pass "dev block: the dev login switch" || fail "dev block lacks '# SPOOL_AUTH_DEV_LOGIN_ENABLED=true'"
has "# SPOOL_HUB_ENV=lde" && pass "dev block: SPOOL_HUB_ENV=lde" || fail "dev block lacks '# SPOOL_HUB_ENV=lde'"
grep -qE '^# SPOOL_HUB_ENV=(dev|prd)$' <<<"$blk" && fail "dev block sets SPOOL_HUB_ENV to dev or prd" || pass "dev block never sets SPOOL_HUB_ENV=dev/prd"

# --- 4. dev secrets = the compose defaults -----------------------------------------
n=0
for v in SPOOL_DB_OWNER_PASSWORD SPOOL_DB_RUNTIME_PASSWORD SPOOL_S3_ACCESS_KEY; do
  want=$(sed -nE "s/.*\\\$\\{$v:-([^}]*)\\}.*/\\1/p" "$dc" | sed -n 1p)
  got=$(sed -nE "s/^# $v=//p" <<<"$blk")
  [[ -n "$want" ]] || { fail "docker-compose.yml has no \${$v:-<default>}"; continue; }
  [[ "$got" == "$want" ]] && { pass "dev block $v = compose default $want"; n=$((n + 1)); } || fail "dev block $v='$got', compose default '$want'"
done
[[ "$n" -eq 3 ]] && pass "all 3 dev secrets match the compose" || fail "$n of 3 dev secrets match the compose"

# --- 5. nothing active by default --------------------------------------------------
act=$(grep -nvE '^(#.*)?$' "$ex")
[[ -z "$act" ]] && pass "every line of .env.example is a comment or blank" || fail "active lines in .env.example: $act"

# --- 6. placeholders only ----------------------------------------------------------
hosts=$(grep -oE '[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(org|com|net|io|dev|app|cloud|fi|se|eu)\b' <<<"$blk" | grep -vxF example.org | sort -u)
[[ -z "$hosts" ]] && pass "dev block names no real domain" || fail "dev block names a domain: $hosts"
grep -qE '[0-9a-fA-F]{32,}' <<<"$blk" && fail "dev block carries a hex key" || pass "dev block carries no hex key"

# --- CONTROL -------------------------------------------------------------------------
grep -qE 'smtp\.example\.org|SPOOL_HUB_ENV=prd' <<<"$blk" && fail "control: the block read is the own-domain one" || pass "control: the block read is the dev one"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
