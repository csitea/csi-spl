#!/usr/bin/env bash
#------------------------------------------------------------------------------
# do_spl_channel_restore (SPL-72, rdb 0052, channels-v1 §5.4):
#   1. DRY_RUN (default) calls no cloud; bad input is refused before any call
#   2. DRY_RUN=0 runs as the env's project SA through the proxy, in the
#      tenant's RLS scope; values reach psql as -v variables (never spliced
#      into the SQL); the DSN is never printed
#   3. it clears the soft-delete stamp of a DELETED row only; no row back is
#      a no-op that says so, not a FATAL
# gcloud and psql are stubbed and record every call (CONTROL: an absent call
# means "not made", not "not recorded").
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
DSN_PW="pw$RANDOM$RANDOM"
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<EOF
#!/usr/bin/env bash
echo "\${CLOUDSDK_CONFIG-<unset>}|\$*" >>"\$STUB_LOG"
case "\$*" in
  "auth activate-service-account"*) for a; do [[ "\$a" == --key-file=* ]] && jq -r .client_email "\${a#*=}" >"\$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "\$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo tok ;;
  "secrets versions access"*) echo "postgres://spool_hub:$DSN_PW@/spool?host=/cloudsql/p:r:i" ;;
esac
exit 0
EOF
# psql: record argv and stdin; answer $PSQL_OUT (default: one returned row)
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || cat >>"$T_STDIN"
printf '%s' "${PSQL_OUT-t1 | doomed | HUM-4
}"
EOF
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

G=(TENANT_ID=t1 CHANNEL=doomed)

# --- 1. dry run + input ---------------------------------------------------------------
in_orc do_spl_channel_restore "${G[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would restore #doomed' "$T/out" && pass "1. DRY_RUN: no cloud call" || fail "1. dry: rc=$rc $(cat "$T/out")"
for bad in "CHANNEL=doomed' or '1'='1" 'CHANNEL=Doomed' 'CHANNEL=' 'TENANT_ID=T 1' 'TENANT_ID=' 'DRY_RUN=yes'; do
  in_orc do_spl_channel_restore "${G[@]}" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. $bad refused before any call" || fail "1. $bad: rc=$rc"
done

# --- 2. real restore ------------------------------------------------------------------
in_orc do_spl_channel_restore "${G[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" && grep -q 'restored' "$T/out" \
  && pass "2. DRY_RUN=0 runs as the env SA $DEV_SA and restores" || fail "2. real: rc=$rc $(cat "$T/out" "$T/calls.log")"
grep -q '\[tenant=t1\]' "$T/calls.log" && grep -q '\[channel=doomed\]' "$T/calls.log" && ! grep -q 'doomed' "$T/stdin" \
  && pass "2. values reach psql as -v variables; the SQL holds only :'var' references" || fail "2. vars: $(cat "$T/calls.log")"
grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" && pass "2. runs in the tenant's RLS scope" || fail "2. no tenant RLS scope"
grep -q "SET deleted_at = NULL, deleted_by = NULL" "$T/stdin" && grep -q "AND deleted_at IS NOT NULL" "$T/stdin" \
  && pass "3. clears the stamp of a deleted row only" || fail "3. statement: $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" && fail "2. the DSN password leaked" || pass "2. the DSN password is in neither output nor argv"
in_orc do_spl_channel_restore "${G[@]}" DRY_RUN=0 PSQL_OUT=''; rc=$?
[[ $rc -eq 0 ]] && grep -q 'nothing to restore' "$T/out" && pass "3. a channel that is not deleted is a no-op that says so" || fail "3. absent: rc=$rc $(cat "$T/out")"

# --- identity: never the owner account -------------------------------------------------
in_orc do_spl_channel_restore "${G[@]}" DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json" HOME="$T/nohome"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" && pass "2. no SA key: refused, no proxy, no psql" || fail "2. no key: rc=$rc $(cat "$T/calls.log")"

echo "channel-restore: $fails failure(s)"
[[ $fails -eq 0 ]]
