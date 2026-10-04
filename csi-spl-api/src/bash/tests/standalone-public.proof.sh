#!/usr/bin/env bash
# specs/047 W9 + W18, proven on the real compose stack (run from the repo
# root, images already built - workflow 50 runs it after its local proof):
#   1. a public URL with the public default DB passwords: hub-init refuses (W9)
#   2. own passwords but no SPOOL_OWNER_EMAIL: hub-init refuses (W18)
#   3. with SPOOL_OWNER_EMAIL: a stranger who signs up FIRST is refused, the
#      owner's address is admitted as biz_owner, a later stranger is refused
#   4. CONTROL: the same stack forced to the old rule (SPOOL_BOOTSTRAP_OWNER=
#      true): the stranger who signs up first becomes the owner
# The hub keeps SPOOL_HUB_ENV=lde and the on-screen confirmation links, so no
# mail relay is needed; the public URL is https://chat.example.org, reached
# through the published port. It deletes its volumes (docker compose down -v).
set -uo pipefail
PORT="${SPOOL_HTTP_PORT:-8080}"
BASE="http://localhost:$PORT"
PUBLIC=https://chat.example.org
fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
dc() { docker compose "$@"; }
fresh() { dc down -v --remove-orphans >/dev/null 2>&1; }
init_log() { dc logs --no-color hub-init 2>/dev/null | tail -n 3; }
healthy() { for _ in $(seq 1 60); do curl -fsS -o /dev/null "$BASE/healthz" 2>/dev/null && return 0; sleep 2; done; return 1; }

# claim <email>: sign up, confirm with the on-screen token, sign in to the
# seeded tenant. Prints the login HTTP status.
claim() {
  local e="$1" pw="pw-$RANDOM-$RANDOM-long" tok
  local -a j=(-sS -H 'Content-Type: application/json' -H "Origin: $PUBLIC")
  tok="$(curl "${j[@]}" -X POST "$BASE/api/v1/auth/register" -d "{\"email\":\"$e\",\"password\":\"$pw\",\"name\":\"x\"}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("debug_token",""))' 2>/dev/null)"
  [[ -n "$tok" ]] || { echo "no-token"; return; }
  curl "${j[@]}" -o /dev/null -X POST "$BASE/api/v1/auth/email/verify" -d "{\"token\":\"$tok\",\"password\":\"$pw\"}"
  curl "${j[@]}" -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/auth/login" \
    -d "{\"email\":\"$e\",\"password\":\"$pw\",\"tenant\":\"${SPOOL_TENANT:-main}\"}"
}
role_of() {
  dc exec -T pg psql -U postgres -d "${SPOOL_DB_NAME:-spool_hub}" -tAc \
    "SELECT m.role FROM tenant_memberships m JOIN human_identities i ON i.human_id = m.human_id WHERE i.subject = '$1'" 2>/dev/null
}

export SPOOL_PUBLIC_URL="$PUBLIC"
unset SPOOL_OWNER_EMAIL SPOOL_BOOTSTRAP_OWNER SPOOL_DB_OWNER_PASSWORD SPOOL_DB_RUNTIME_PASSWORD SPOOL_DB_SUPERUSER_PASSWORD

# --- 1. W9 --------------------------------------------------------------------------
fresh
dc up -d web >/dev/null 2>&1 && fail "1. up with the default passwords on a public URL succeeded" ||
  { init_log | grep 'still the public defaults' >/dev/null && pass "1. W9: public URL + default DB passwords -> hub-init refuses, up fails" ||
    fail "1. W9: $(init_log)"; }

# --- 2. W18, no owner email ---------------------------------------------------------------
export SPOOL_DB_OWNER_PASSWORD="o-$(openssl rand -hex 12)" SPOOL_DB_RUNTIME_PASSWORD="r-$(openssl rand -hex 12)" SPOOL_DB_SUPERUSER_PASSWORD="s-$(openssl rand -hex 12)"
fresh
dc up -d web >/dev/null 2>&1 && fail "2. up with no SPOOL_OWNER_EMAIL on a public URL succeeded" ||
  { init_log | grep 'set SPOOL_OWNER_EMAIL' >/dev/null && pass "2. W18: public URL + no SPOOL_OWNER_EMAIL -> hub-init refuses" || fail "2. W18: $(init_log)"; }

# --- 3. W18, the owner invite ---------------------------------------------------------------
export SPOOL_OWNER_EMAIL=owner@example.org
fresh
if dc up -d web >/dev/null 2>&1 && healthy; then
  dc logs --no-color hub-init | grep "OWNER: open $PUBLIC/login" >/dev/null && pass "3. hub-init prints the one-time owner link" || fail "3. no owner link: $(init_log)"
  c="$(claim intruder@example.org)"; [[ "$c" == 403 ]] && pass "3. a stranger who signs up FIRST is refused ($c)" || fail "3. stranger first: $c"
  c="$(claim owner@example.org)"; r="$(role_of owner@example.org)"
  [[ "$c" == 200 && "$r" == biz_owner ]] && pass "3. the owner's address is admitted as biz_owner" || fail "3. owner: login $c role '$r'"
  c="$(claim intruder2@example.org)"; [[ "$c" == 403 ]] && pass "3. a later stranger is refused ($c)" || fail "3. later stranger: $c"
else
  fail "3. the public stack with SPOOL_OWNER_EMAIL did not come up: $(init_log)"
fi

# --- 4. CONTROL -------------------------------------------------------------------------------
export SPOOL_BOOTSTRAP_OWNER=true
fresh
if dc up -d web >/dev/null 2>&1 && healthy; then
  c="$(claim intruder@example.org)"; r="$(role_of intruder@example.org)"
  [[ "$c" == 200 && "$r" == biz_owner ]] && pass "4. CONTROL: with the old rule the first stranger owns the tenant (this proof can see the hole)" ||
    fail "4. CONTROL: login $c role '$r'"
else
  fail "4. the control stack did not come up: $(init_log)"
fi
fresh

[[ "$fails" -eq 0 ]] && { echo "ALL standalone-public CHECKS PASSED"; exit 0; }
echo "FAILED standalone-public: $fails"; exit 1
