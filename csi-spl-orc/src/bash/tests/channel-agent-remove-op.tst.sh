#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_channel_agent_remove_op (the operator mirror of the hub's
#          DELETE /v1/channels/{channel}/agents/{box}/{id}) stays offline on
#          DRY_RUN and bad input; a real run is one transaction that marks the
#          live seats origin='removed', with values as psql variables.
#          gcloud and psql are stubbed.
#   1. DRY_RUN (default) prints the plan, calls no cloud; ids are deduped
#   2. bad input (#issues, #tasks, box-wui, a non-agent id) refused before any call;
#      a default channel is allowed, as on the hub
#   3. DRY_RUN=0: one transaction, UPDATE ... origin='removed' only (no DELETE,
#      no INSERT), app.tenant_id set, values as -v, as the env SA
#   4. runner: removed / absent reported; a count mismatch or psql failure is FATAL
#   5. one copy (r13-03): _spl_channel_agent_ids in spl-channel-agent-add-op.func.sh
#      checks AGENT_BOX and AGENTS for both operator actions; remove_op sourced
#      alone loads it and keeps its plan, dedupe and refusals
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
DSN_PW="pw$RANDOM$RANDOM"
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/state"
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
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
[[ -t 0 ]] || cat >>"$T_STDIN"
if [[ -n "${STUB_PSQL_FILE:-}" ]]; then
  cat "$STUB_PSQL_FILE"
elif [[ -n "${STUB_PSQL_OUT+x}" ]]; then
  printf '%s\n' "$STUB_PSQL_OUT"
else
  printf '%s\n' 'removed | c-001'
fi
exit "${STUB_PSQL_RC:-0}"
EOF
for b in cloud-sql-proxy docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u HUMAN_ID -u EMAIL \
    -u TENANT_ID -u CHANNEL -u AGENTS -u AGENT_BOX -u SPOOL_DESK_BOX -u STUB_PSQL_OUT -u STUB_PSQL_FILE -u STUB_PSQL_RC \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" SPOOL_BOX_ENV="$T/box.env" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

FUNC="$PROJ_ROOT/src/bash/run/spl-channel-agent-remove-op.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
sqlbody=$(awk 'index($0, "<<'\''SQL'\''") {p=1; next} $0=="SQL" {p=0} p' "$FUNC")
[[ -n "$sqlbody" ]] && ! grep -q '\$' <<<"$sqlbody" \
  && pass "0. the SQL heredoc has no shell expansion" || fail "0. the SQL heredoc is empty or expanded by the shell"

# --- 1. DRY_RUN --------------------------------------------------------------------
in_orc 'do_spl_channel_agent_remove_op' TENANT_ID=t1 CHANNEL=spool-hub-devel AGENTS='c-001 c-001'; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would remove c-001 on box-desk from #spool-hub-devel in t1 (origin=removed)' "$T/out" \
  && [[ $(grep -o 'c-001' "$T/out" | wc -l) -eq 1 ]] \
  && pass "1. DRY_RUN (default): plan, deduped, no cloud" || fail "1. dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
in_orc 'do_spl_channel_agent_remove_op' TENANT_ID=t1 CHANNEL=general AGENTS=c-001; rc=$?
[[ $rc -eq 0 ]] && grep -q 'from #lobby in t1' "$T/out" && pass "1. #general is #lobby, and a default channel is allowed" || fail "1. general: $(cat "$T/out")"

# --- 2. refusals -------------------------------------------------------------------
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_channel_agent_remove_op' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $label refused before any call" || fail "2. $label: rc=$rc $(cat "$T/out")"
}
base=(TENANT_ID=t1 CHANNEL=spool-hub-devel AGENTS=c-001)
refuse "reserved issues" TENANT_ID=t1 CHANNEL=issues AGENTS=c-001 DRY_RUN=0
refuse "retired tasks" TENANT_ID=t1 CHANNEL=tasks AGENTS=c-001 DRY_RUN=0
refuse "bad tenant" TENANT_ID=T_1 CHANNEL=x AGENTS=c-001 DRY_RUN=0
refuse "bad channel" TENANT_ID=t1 CHANNEL='A b' AGENTS=c-001 DRY_RUN=0
refuse "missing AGENTS" TENANT_ID=t1 CHANNEL=x DRY_RUN=0
refuse "human id" TENANT_ID=t1 CHANNEL=x AGENTS=HUM-4 DRY_RUN=0
refuse "injected agent" TENANT_ID=t1 CHANNEL=x "AGENTS=c-001' or '1'='1" DRY_RUN=0
refuse "box-wui" "${base[@]}" AGENT_BOX=box-wui DRY_RUN=0
refuse "DRY_RUN=2" "${base[@]}" DRY_RUN=2

# --- 3. the transaction ----------------------------------------------------------------
in_orc 'do_spl_channel_agent_remove_op' "${base[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'BEGIN;' "$T/stdin" && grep -qx 'COMMIT;' "$T/stdin" \
  && grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" \
  && grep -q "SET origin = 'removed'" "$T/stdin" && grep -q "c.origin <> 'removed'" "$T/stdin" \
  && ! grep -qiE '\b(delete|insert|drop|truncate|alter)\b' "$T/stdin" \
  && grep -q '\[channel=spool-hub-devel\]' "$T/calls.log" && grep -q '\[agents=c-001\]' "$T/calls.log" \
  && ! grep -q 'c-001' "$T/stdin" && ! grep -q 'spool-hub-devel' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q "OK removed c-001 on box-desk from #spool-hub-devel in t1 ($DEV_SA)" "$T/out" \
  && pass "3. DRY_RUN=0: one UPDATE-only transaction, values as -v, as $DEV_SA" \
  || fail "3. real: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "3. the DSN password leaked" || pass "3. the DSN password is in neither output, argv nor SQL"

# --- 4. runner messages -------------------------------------------------------------------
in_orc 'do_spl_channel_agent_remove_op' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='absent | c-001'; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK c-001 had no seat in #spool-hub-devel on box-desk in t1 - nothing to remove' "$T/out" \
  && pass "4. an agent with no seat is reported, nothing changes" || fail "4. absent: rc=$rc $(cat "$T/out")"
printf '%s\n' 'removed | c-001' 'absent | c-002' >"$T/mix.out"
in_orc 'do_spl_channel_agent_remove_op' TENANT_ID=t1 CHANNEL=x AGENTS='c-001 c-002' DRY_RUN=0 STUB_PSQL_FILE="$T/mix.out"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK removed c-001' "$T/out" && grep -q 'OK c-002 had no seat' "$T/out" \
  && pass "4. a mix is reported per agent" || fail "4. mix: $(cat "$T/out")"
in_orc 'do_spl_channel_agent_remove_op' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='refuse-count'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'unexpected number of rows; rolled back' "$T/out" && pass "4. a count mismatch is FATAL" || fail "4. count: $(cat "$T/out")"
in_orc 'do_spl_channel_agent_remove_op' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='' ; rc=$?
[[ $rc -ne 0 ]] && grep -q 'returned 0 removed and 0 absent, want 1' "$T/out" && pass "4. an empty result is FATAL" || fail "4. empty: $(cat "$T/out")"
in_orc 'do_spl_channel_agent_remove_op' "${base[@]}" DRY_RUN=0 STUB_PSQL_RC=2 STUB_PSQL_OUT='boom'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'failed: boom' "$T/out" && pass "4. a psql failure is FATAL" || fail "4. psql rc: $(cat "$T/out")"

# --- 5. _spl_channel_agent_ids, one copy, remove_op alone (r13-03) -------------------
ADD="$PROJ_ROOT/src/bash/run/spl-channel-agent-add-op.func.sh"
ids_of() {
  env PROJ_PATH="$PROJ_ROOT" BOX_ARG="$1" IDS_ARG="$2" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$1"; v="$IDS_ARG"; _spl_channel_agent_ids v "$BOX_ARG" || exit $?
    printf "IDS=[%s]\n" "$v"' _ "$ADD" 2>&1
}
out=$(ids_of box-desk 'c-002 c-001 c-002'); rc=$?
[[ $rc -eq 0 && "$out" == "IDS=[c-002 c-001]" ]] && pass "5. _spl_channel_agent_ids dedupes in first-seen order" || fail "5. dedupe ($rc: $out)"
out=$(ids_of box-wui c-001); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENT_BOX 'box-wui' is not a box id (box-wui is reserved)"* ]] && pass "5. _spl_channel_agent_ids refuses box-wui" || fail "5. box-wui ($rc: $out)"
out=$(ids_of box-desk ''); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENTS must name at least one agent id"* ]] && pass "5. _spl_channel_agent_ids refuses an empty list" || fail "5. empty ($rc: $out)"
out=$(ids_of box-desk 'c-001 HUM-4'); rc=$?
[[ $rc -eq 1 && "$out" == *"FATAL AGENTS entry 'HUM-4' is not an agent id"* ]] && pass "5. _spl_channel_agent_ids refuses a non-agent id" || fail "5. human ($rc: $out)"
alone() {
  : >"$T/calls.log"
  env -u DRY_RUN -u AGENT_BOX -u SPOOL_DESK_BOX HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    SPOOL_BOX_ENV="$T/box.env" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
    source "$PROJ_PATH/src/bash/run/spl-channel-agent-remove-op.func.sh"
    do_spl_channel_agent_remove_op' >"$T/out" 2>&1 </dev/null
}
alone TENANT_ID=t1 CHANNEL=spool-hub-devel AGENTS='c-001 c-001'; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" && $(grep -o 'c-001' "$T/out" | wc -l) -eq 1 ]] \
  && grep -q 'DRY_RUN would remove c-001 on box-desk from #spool-hub-devel in t1 (origin=removed)' "$T/out" \
  && pass "5. remove_op alone loads the helper: plan, deduped, no cloud" || fail "5. alone dry: rc=$rc $(cat "$T/out")"
alone TENANT_ID=t1 CHANNEL=x AGENTS=c-001 AGENT_BOX=box-wui DRY_RUN=0; rc=$?
[[ $rc -eq 1 && ! -s "$T/calls.log" ]] && grep -q "FATAL AGENT_BOX 'box-wui' is not a box id (box-wui is reserved)" "$T/out" \
  && pass "5. remove_op alone refuses box-wui before any call" || fail "5. alone box-wui: rc=$rc $(cat "$T/out")"
[[ $(grep -c '^_spl_channel_agent_ids()' "$ADD") -eq 1 ]] && grep -q '_spl_channel_agent_ids agents "$box" || return 1' "$ADD" \
  && pass "5. one copy: spl-channel-agent-add-op.func.sh hosts and calls _spl_channel_agent_ids" || fail "5. host"
own=$(grep -nE 'is not a box id|AGENTS entry|seen\[\$a\]|spl_is_agent_id' "$FUNC" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
[[ -z "$own" ]] && grep -q '_spl_channel_agent_ids agents "$box" || return 1' "$FUNC" \
  && pass "5. one copy: remove_op delegates to _spl_channel_agent_ids" || fail "5. remove_op own=[$own]"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
