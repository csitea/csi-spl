#!/usr/bin/env bash
# Workspace agent caps end to end (spec 147 section 8, R6, SPL-2676) with the
# real binary against a migrated Postgres: the spool-hub admin (an admin of
# the operator workspace) caps example-ws by vendor over
# PUT /v1/operator/workspaces/{id}/agent-caps, an admin of example-ws is
# refused that route (control C2) and reads the caps read-only over
# GET /v1/tenant/agent-caps, and box hellos seat agents only up to each cap
# (the SetRoster gate trims the rest; an uncapped vendor seats freely).
#   1. CONTROL: with no caps set, a 2nd claude seats (the gate is what refuses)
#   2. C2: the example-ws admin's PUT is 403 forbidden operator.workspaces
#   3. the operator admin's PUT/GET; bad vendor and bad cap are 400
#   4. a hello over the claude cap of 1 and the agy cap of 2 is trimmed;
#      qwen (no cap) seats both; the tenant read shows caps, live, can_edit
#   5. `spool caps check` exits 3 naming the cap, 0 under it
#   6. DELETE of the claude cap: the next hello seats the trimmed claude
# Usage: bash workspace-agent-caps.tst.sh <spool-binary> <postgres-dsn>
#   (hub-pg.tst.sh calls it with the runtime-role DSN)
set -euo pipefail

BIN="$1"
DSN="$2"
WORK="$(mktemp -d)"
PORT=""
OP="op-ws"
WS="example-ws"
LOBBY="00000000-0000-4000-8000-000000000001"
PW="caps-test-password-$RANDOM-$RANDOM"
HUB_PID=""
cleanup() {
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL - $*"; [ -f "$WORK/hub.log" ] && tail -20 "$WORK/hub.log"; exit 1; }
ok() { echo "ok   - $*"; }

# 0. two workspaces, a root key each for example-ws's boxes, one admin each
ROOT_PUB="$("$BIN" root-keygen --out "$WORK/root.key")"
SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-tenant --tenant "$OP" --root-pubkey "$("$BIN" root-keygen --out "$WORK/op-root.key")" >/dev/null
SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-tenant --tenant "$WS" --root-pubkey "$ROOT_PUB" >/dev/null
for m in "$OP op-admin@example.com" "$WS ws-admin@example.com"; do
  read -r t e <<<"$m"
  printf '%s\n' "$PW" | SPOOL_HUB_DB_DSN="$DSN" "$BIN" hub-provision-member --tenant "$t" --email "$e" \
    --name "FirstName LastName" --role admin --password-stdin >/dev/null || fail "provision $e in $t"
done
ok "workspaces $OP (operator) and $WS, one admin each"

# The log exists before the hub starts: the port poll below reads it at once,
# and a sed on a missing file exits 2, which set -e turns into a dead test.
: >"$WORK/hub.log"
SPOOL_HUB_DB_DSN="$DSN" SPOOL_HUB_FILES_DIR="$WORK/blobs" \
SPOOL_HUB_TENANT_HOST_PATTERN="{tenant}.localhost" SPOOL_HUB_LISTEN_ADDR="127.0.0.1:0" \
SPOOL_HUB_LOG_FORMAT=json SPOOL_HUB_ENV=lde SPOOL_HUB_LOBBY_TASK_ID="$LOBBY" \
SPOOL_HUB_VIEW_DOOR=session SPOOL_HUB_OPERATOR_TENANT="$OP" \
SPOOL_HUB_AUTH_NATIVE_ENABLED=true SPOOL_HUB_AUTH_SESSION_KEY="$(head -c 48 /dev/urandom | base64 | tr -d '\n')" \
SPOOL_HUB_AUTH_APP_URL="http://localhost" SPOOL_HUB_AUTH_COOKIE_SECURE=false \
  "$BIN" serve >>"$WORK/hub.log" 2>&1 &
HUB_PID=$!
for _ in $(seq 1 100); do
  PORT="$(sed -n 's/.*"addr":"127\.0\.0\.1:\([0-9][0-9]*\)".*"message":"hub listening".*/\1/p' "$WORK/hub.log" | tail -1)"
  [ -n "$PORT" ] && break
  kill -0 "$HUB_PID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$PORT" ] || fail "hub never logged a listening address"
for _ in $(seq 1 100); do curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
ok "spool serve up (native sign-in, operator workspace $OP)"

# login <tenant> <email>: a session cookie jar at $WORK/<tenant>.jar
login() {
  local code
  code="$(curl -sS -o "$WORK/login.out" -w '%{http_code}' -c "$WORK/$1.jar" -H 'Content-Type: application/json' \
    -X POST "http://$1.localhost:$PORT/api/v1/auth/login" -d "{\"email\":\"$2\",\"password\":\"$PW\",\"tenant\":\"$1\"}")"
  [ "$code" = 200 ] || fail "login $2 in $1: $code $(cat "$WORK/login.out")"
}
# call <jar tenant> <method> <path> [body]: prints "<code> <body>"
call() {
  local code
  code="$(curl -sS -o "$WORK/call.out" -w '%{http_code}' -b "$WORK/$1.jar" -H 'Content-Type: application/json' \
    -X "$2" "http://$1.localhost:$PORT$3" ${4:+-d "$4"})"
  echo "$code $(cat "$WORK/call.out")"
}
# jq_py <json> <python expr over d>: prints the value
jq_py() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

box() { echo "SPOOL_ROOT=$WORK/$1/spool SPOOL_KEYS_DIR=$WORK/$1/keys SPOOL_BOX_ID=$1 SPOOL_HUB_URL=http://$WS.localhost:$PORT"; }
on() { local b="$1" e; shift; read -r -a e <<<"$(box "$b")"; env "${e[@]}" "$BIN" "$@"; }
seat() { # <box> <agent>...: the agent dirs, then a hello
  local b="$1"; shift
  for a in "$@"; do mkdir -p "$WORK/$b/spool/$a/inbox"; done
  on "$b" hub-sync >/dev/null 2>&1 || true
}
live() { # <vendor>: the live count example-ws's admin reads
  local r; r="$(call "$WS" GET /v1/tenant/agent-caps)"
  [ "${r%% *}" = 200 ] || fail "GET /v1/tenant/agent-caps: $r"
  jq_py "${r#* }" "d['live'].get('$1', 0)"
}
for b in box-a box-b box-c; do
  on "$b" pin --box "$b" --pubkey "$(on "$b" keygen)" --root-key "$WORK/root.key" >/dev/null
done
login "$OP" op-admin@example.com
login "$WS" ws-admin@example.com
ok "three boxes pinned in $WS; both admins signed in"

# 1. CONTROL: uncapped, two claudes on two boxes both seat
seat box-c c-901
seat box-b c-902
[ "$(live claude)" = 2 ] || fail "CONTROL: uncapped $WS seats $(live claude) claude, want 2"
ok "CONTROL: with no cap, a 2nd claude seats (2 live)"
rm -rf "$WORK/box-c/spool/c-901" "$WORK/box-b/spool/c-902"
seat box-c
seat box-b
[ "$(live claude)" = 0 ] || fail "CONTROL: an empty hello left $(live claude) claude live"

# 2. C2: example-ws's own admin cannot set its caps
r="$(call "$WS" PUT "/v1/operator/workspaces/$WS/agent-caps" '{"caps":{"claude":9}}')"
[ "${r%% *}" = 403 ] && [ "$(jq_py "${r#* }" "d['error'], d['permission']")" = "('forbidden', 'operator.workspaces')" ] ||
  fail "C2: the $WS admin's PUT answered $r"
ok "C2: the $WS admin's PUT is 403 forbidden operator.workspaces"

# 3. the spool-hub admin sets the caps
r="$(call "$OP" PUT "/v1/operator/workspaces/$WS/agent-caps" '{"caps":{"claude":1,"grok":1,"agy":2,"mistral":1}}')"
[ "${r%% *}" = 200 ] || fail "operator PUT: $r"
[ "$(jq_py "${r#* }" "sorted(d['caps'].items()), d['workspace_id'], d['updated_by'] is not None")" = \
  "([('agy', 2), ('claude', 1), ('grok', 1), ('mistral', 1)], '$WS', True)" ] || fail "operator PUT body: $r"
r="$(call "$OP" GET "/v1/operator/workspaces/$WS/agent-caps")"
[ "${r%% *}" = 200 ] && [ "$(jq_py "${r#* }" "d['caps'].get('qwen')")" = None ] || fail "operator GET: $r"
r="$(call "$OP" PUT "/v1/operator/workspaces/$WS/agent-caps" '{"caps":{"nosuch":1}}')"
[ "${r%% *}" = 400 ] && [ "$(jq_py "${r#* }" "d['error']")" = bad_vendor ] || fail "bad vendor: $r"
r="$(call "$OP" PUT "/v1/operator/workspaces/$WS/agent-caps" '{"caps":{"claude":-1}}')"
[ "${r%% *}" = 400 ] && [ "$(jq_py "${r#* }" "d['error']")" = bad_cap ] || fail "bad cap: $r"
ok "the operator admin caps $WS (claude 1, grok 1, agy 2, mistral 1; qwen unlisted); bad vendor/cap are 400"

# 4. hellos seat up to each cap
seat box-a c-004 a-004
seat box-b c-005 a-005 a-006 q-004 q-005 g-004 g-005 m-004 m-005
r="$(call "$WS" GET /v1/tenant/agent-caps)"
[ "${r%% *}" = 200 ] || fail "tenant GET: $r"
got="$(jq_py "${r#* }" "[d['live'].get(k, 0) for k in ('claude','agy','grok','mistral','qwen')], d['caps']['qwen'], d['caps']['agy'], d['can_edit']")"
[ "$got" = "([1, 2, 1, 1, 2], None, 2, False)" ] || fail "after the hellos (live claude,agy,grok,mistral,qwen; caps qwen, agy; can_edit): $got from $r"
ok "hellos over the caps are trimmed: live claude 1/1, agy 2/2, grok 1/1, mistral 1/1, qwen 2 (uncapped); can_edit false"
r="$(call "$WS" POST /v1/tenant/agent-caps '{}')"
[ "${r%% *}" = 405 ] || fail "tenant POST: $r"
ok "the tenant read is GET only (POST 405)"

# 5. the box's own check
rc=0; out="$(on box-a caps check c-006 2>&1)" || rc=$?
[ "$rc" = 3 ] && grep -qF "agent c-006 (claude) exceeds workspace $WS cap of 1 (currently 1 live); seating refused" <<<"$out" ||
  fail "caps check c-006: rc=$rc $out"
rc=0; out="$(on box-a caps check q-006 2>&1)" || rc=$?
[ "$rc" = 0 ] || fail "caps check q-006: rc=$rc $out"
ok "spool caps check: c-006 exit 3 naming cap 1 and 1 live; q-006 exit 0"

# 6. the cap lifted: the next hello seats the trimmed claude
r="$(call "$OP" DELETE "/v1/operator/workspaces/$WS/agent-caps/claude")"
[ "${r%% *}" = 204 ] || fail "DELETE claude cap: $r"
seat box-b
[ "$(live claude)" = 2 ] || fail "after DELETE: live claude $(live claude), want 2"
ok "DELETE of the claude cap (204): box-b's next hello seats c-005 (2 live)"

echo "ALL WORKSPACE AGENT CAPS CHECKS PASSED"
