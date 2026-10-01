#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_tenant_test_purge (owner, t1 bea3a4e6: unused dev test
#          workspaces are clutter), CALLED against a stub psql:
#          - refused before any SQL: ENV=prd, an empty list, an invalid id,
#            a mapped tenant (env.dns.mapped_tenants)
#          - refused after the guard read, before any backup or delete: a
#            workspace with a message, one with a ready host
#          - dry run (default): a 0600 backup with one object per tenant_id
#            table, no DELETE
#          - DRY_RUN=0: backup first, then ONE transaction with the DELETE and
#            the host rows closed as removed; the after-check passes
#          - CONTROL: an after-check that still sees a tenant fails the run
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/db"

# stub psql: answers by the SQL it is fed; every write lands in $DB/writes
cat >"$T/bin/psql" <<'SH'
#!/usr/bin/env bash
sql=""
while (($#)); do [[ "$1" == -c ]] && { sql="$2"; shift; }; shift; done
[[ -n "$sql" ]] || sql="$(cat)"
case "$sql" in
  *"SELECT 'row'"*)
    for t in $(grep -o "ARRAY\[[^]]*\]" <<<"$sql" | head -1 | tr -d "ARY[]'" | tr ',' ' '); do
      m=0 h=pending; [[ "$t" == "${MSG_TENANT:-}" ]] && m=3; [[ "$t" == "${READY_TENANT:-}" ]] && h=ready
      echo "row $t t $m 0 $h"
    done ;;
  *information_schema*) printf 'channels\ntenants\n' ;;
  *json_build_object*)
    echo '{"table" : "channels", "rows" : [{"tenant_id":"a1"}]}'
    echo '{"table" : "tenants", "rows" : [{"tenant_id":"a1"}]}' ;;
  *BEGIN*) printf '%s\n' "$sql" >>"$DB/writes" ;;
  *"SELECT 'after'"*) echo "after ${AFTER_LEFT:-0} 0" ;;
esac
SH
chmod +x "$T/bin/psql"
printf '#!/bin/sh\ncase "$*" in "auth print-access-token"*) echo ya29.stub_token_value_long_enough ;; esac\nexit 0\n' >"$T/bin/gcloud"
chmod +x "$T/bin/gcloud"

run_act() {  # [VAR=value ...]
  local o rc
  rm -f "$T/db/writes" "$T/bk.jsonl"
  o=$(env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      DB="$T/db" ENV=dev PURGE_BACKUP="$T/bk.jsonl" PURGE_TENANTS="a1 b2" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_gcp_pin_account() { GCP_ACCOUNT=stub-sa@example.com; }
    do_gcp_require_live_account() { :; }
    spl_via_proxy() { SPL_PROXY_DSN="postgres://u:p@127.0.0.1:5999/db" "$@"; }
    do_spl_tenant_test_purge' 2>&1); rc=$?
  printf '%s\n' "$o"; return $rc
}

out=$(run_act ENV=prd DRY_RUN=0); rc=$?
[[ $rc -ne 0 && ! -f "$T/bk.jsonl" ]] && pass "refused: prd" || fail "prd: rc=$rc $out"
out=$(run_act PURGE_TENANTS="" DRY_RUN=0); rc=$?
[[ $rc -ne 0 && ! -f "$T/bk.jsonl" ]] && pass "refused: an empty list (no default)" || fail "empty: rc=$rc $out"
out=$(run_act PURGE_TENANTS="a1 'x;drop" DRY_RUN=0); rc=$?
[[ $rc -ne 0 && ! -f "$T/bk.jsonl" ]] && pass "refused: an invalid id" || fail "invalid: rc=$rc $out"
mapped="$(yq -r '.env.dns.mapped_tenants[0] // ""' "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml")"
out=$(run_act PURGE_TENANTS="a1 $mapped" DRY_RUN=0); rc=$?
[[ -n "$mapped" && $rc -ne 0 && ! -f "$T/bk.jsonl" ]] && pass "refused: a mapped tenant ($mapped)" || fail "mapped: rc=$rc $out"
out=$(run_act MSG_TENANT=b2 DRY_RUN=0); rc=$?
[[ $rc -ne 0 && ! -f "$T/bk.jsonl" && ! -f "$T/db/writes" ]] && pass "refused: a workspace with messages, before backup or delete" || fail "msgs: rc=$rc $out"
out=$(run_act READY_TENANT=a1 DRY_RUN=0); rc=$?
[[ $rc -ne 0 && ! -f "$T/db/writes" ]] && pass "refused: a workspace with a ready host" || fail "ready: rc=$rc $out"

out=$(run_act); rc=$?
[[ $rc -eq 0 && -f "$T/bk.jsonl" && ! -f "$T/db/writes" && "$(stat -c %a "$T/bk.jsonl")" == 600 ]] &&
  pass "dry run: a 0600 backup, no DELETE" || fail "dry: rc=$rc $out"
[[ "$(jq -s -r '[.[].table] | join(",")' "$T/bk.jsonl" 2>/dev/null)" == "channels,tenants" ]] &&
  pass "the backup holds one object per tenant_id table" || fail "backup shape: $(cat "$T/bk.jsonl" 2>/dev/null)"

out=$(run_act DRY_RUN=0); rc=$?
w="$(cat "$T/db/writes" 2>/dev/null)"
[[ $rc -eq 0 && -f "$T/bk.jsonl" ]] && grep -q "DELETE FROM tenants WHERE tenant_id = ANY(ARRAY\['a1','b2'\]::text\[\])" <<<"$w" &&
  grep -q "SET status = 'removed'" <<<"$w" && grep -q COMMIT <<<"$w" &&
  pass "DRY_RUN=0: backup, then one transaction deleting the tenants and closing the host rows" || fail "wet: rc=$rc $out / $w"

out=$(run_act DRY_RUN=0 AFTER_LEFT=1); rc=$?
[[ $rc -ne 0 ]] && grep -q "remain" <<<"$out" && pass "CONTROL: a tenant still present after the purge fails the run" || fail "after: rc=$rc $out"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
