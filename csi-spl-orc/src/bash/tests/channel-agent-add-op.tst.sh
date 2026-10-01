#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_channel_agent_add_op stays offline on DRY_RUN and on bad
#          input, and a real run sends one transaction whose values are psql
#          variables. gcloud and psql are stubbed (an absent call is absent).
#   1. DRY_RUN (the default) prints the plan and calls no cloud. AGENT_BOX
#      defaults to box-desk. A repeated agent id is named once.
#   2. bad input, including a default channel and box-wui, is refused before
#      any gcloud or psql call.
#   3. DRY_RUN=0 with no project SA key never reaches psql.
#   4. DRY_RUN=0 runs as the env SA. The SQL inserts channel_subscriptions
#      with origin invite, ON CONFLICT DO NOTHING, revives a removed seat,
#      requires the roster and a live channel, and sets app.tenant_id. The
#      agent ids, the channel and the box are -v values, not text in the script.
#   5. the runner says so when an agent is already a member, and refuses an
#      agent that is not on the roster, a missing channel, or a count mismatch.
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
  printf '%s\n' 'added | CLE-7'
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
    -u TENANT_ID -u CHANNEL -u AGENTS -u AGENT_BOX -u STUB_PSQL_OUT -u STUB_PSQL_FILE -u STUB_PSQL_RC \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

FUNC="$PROJ_ROOT/src/bash/run/spl-channel-agent-add-op.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
sqlbody=$(awk 'index($0, "<<'\''SQL'\''") {p=1; next} $0=="SQL" {p=0} p' "$FUNC")
[[ -n "$sqlbody" ]] && ! grep -q '\$' <<<"$sqlbody" \
  && pass "0. the SQL heredoc has no shell expansion" \
  || fail "0. the SQL heredoc is empty or expanded by the shell"

# --- 1. DRY_RUN plan, no cloud ------------------------------------------------
in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=release-notes AGENTS='CLE-7 CLE-8'; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would add CLE-7 CLE-8 on box-desk to #release-notes in t1 (origin=invite)' "$T/out" \
  && grep -q 'on csi-spl-dev:' "$T/out" \
  && grep -q 'Re-run with DRY_RUN=0' "$T/out" \
  && pass "1. DRY_RUN (default): plan names box-desk, no cloud" \
  || fail "1. dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=release-notes AGENTS='CLE-7 CLE-7' AGENT_BOX=box-a DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would add CLE-7 on box-a to #release-notes in t1 (origin=invite)' "$T/out" \
  && [[ $(grep -o 'CLE-7' "$T/out" | wc -l) -eq 1 ]] \
  && pass "1. a repeated agent id is named once, and AGENT_BOX is honoured" \
  || fail "1. dedupe: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_agent_add_op' ENV=prd TENANT_ID=t1 CHANNEL=release-notes AGENTS=CLE-7 DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'on csi-spl-prd:' "$T/out" \
  && pass "1. prd DRY_RUN names the prd connection and calls no cloud" \
  || fail "1. prd dry: rc=$rc $(cat "$T/out")"

# --- 2. bad input, before any call --------------------------------------------
base=(TENANT_ID=t1 CHANNEL=release-notes AGENTS=CLE-7)
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_channel_agent_add_op' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $label refused before any call" || fail "2. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "missing TENANT_ID" CHANNEL=release-notes AGENTS=CLE-7 DRY_RUN=0
refuse "bad tenant slug" TENANT_ID=T_1 CHANNEL=release-notes AGENTS=CLE-7 DRY_RUN=0
refuse "missing CHANNEL" TENANT_ID=t1 AGENTS=CLE-7 DRY_RUN=0
refuse "bad channel id" TENANT_ID=t1 CHANNEL='Rel Notes' AGENTS=CLE-7 DRY_RUN=0
refuse "default lobby" TENANT_ID=t1 CHANNEL=lobby AGENTS=CLE-7 DRY_RUN=0
refuse "default alerts" TENANT_ID=t1 CHANNEL=alerts AGENTS=CLE-7 DRY_RUN=0
refuse "default feedback" TENANT_ID=t1 CHANNEL=feedback AGENTS=CLE-7 DRY_RUN=0
refuse "default tasks" TENANT_ID=t1 CHANNEL=tasks AGENTS=CLE-7 DRY_RUN=0
refuse "general alias" TENANT_ID=t1 CHANNEL=general AGENTS=CLE-7 DRY_RUN=0
refuse "reserved issues" TENANT_ID=t1 CHANNEL=issues AGENTS=CLE-7 DRY_RUN=0
refuse "missing AGENTS" TENANT_ID=t1 CHANNEL=release-notes DRY_RUN=0
refuse "human id as an agent" TENANT_ID=t1 CHANNEL=release-notes AGENTS=HUM-4 DRY_RUN=0
refuse "box id as an agent" TENANT_ID=t1 CHANNEL=release-notes AGENTS=BOX-1 DRY_RUN=0
refuse "lower-case agent" TENANT_ID=t1 CHANNEL=release-notes AGENTS=cle-7 DRY_RUN=0
refuse "injected agent" TENANT_ID=t1 CHANNEL=release-notes "AGENTS=CLE-7' or '1'='1" DRY_RUN=0
refuse "box-wui" "${base[@]}" AGENT_BOX=box-wui DRY_RUN=0
refuse "bad AGENT_BOX" "${base[@]}" AGENT_BOX='Box_A' DRY_RUN=0
refuse "DRY_RUN=2" "${base[@]}" DRY_RUN=2
in_orc 'do_spl_channel_agent_add_op' ENV=stg "${base[@]}" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. ENV=stg refused before any call" || fail "2. ENV=stg: rc=$rc $(cat "$T/out")"

# --- 3. no project SA key -----------------------------------------------------
in_orc 'do_spl_channel_agent_add_op' "${base[@]}" DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "3. no SA key: refused, no proxy, no psql" || fail "3. no key: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 4. the transaction -------------------------------------------------------
sql_shape() {
  grep -qx 'BEGIN;' "$T/stdin" && grep -qx 'COMMIT;' "$T/stdin" \
    && grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" \
    && grep -q 'INSERT INTO channel_subscriptions (tenant_id, channel_id, agent_id, box_id, origin)' "$T/stdin" \
    && grep -q "SELECT :'tenant', :'channel', w.a, :'box', 'invite'" "$T/stdin" \
    && grep -q 'ON CONFLICT (tenant_id, channel_id, agent_id, box_id) DO NOTHING' "$T/stdin" \
    && grep -q 'UPDATE channel_subscriptions AS c' "$T/stdin" \
    && grep -q 'SET origin = '"'"'invite'"'"'' "$T/stdin" \
    && grep -q "c.origin = 'removed'" "$T/stdin" \
    && grep -q 'FROM roster r' "$T/stdin" \
    && grep -q 'deleted_at IS NULL' "$T/stdin" \
    && grep -q 'string_to_array(:'"'"'agents'"'"'' "$T/stdin" \
    && grep -q "(:'channel' IN ('tasks', 'issues', 'general')" "$T/stdin" \
    && grep -q "OR (:'channel' IN ('lobby', 'alerts', 'feedback') AND :'allowdef' <> '1')" "$T/stdin" \
    && grep -q "format('refuse-not-a-member | %s'" "$T/stdin" \
    && grep -q "format('refuse-channel | %s'" "$T/stdin" \
    && grep -q "format('refuse-public | %s'" "$T/stdin" \
    && grep -q "format('already | %s'" "$T/stdin" \
    && grep -q "format('added | %s'" "$T/stdin" \
    && grep -qx "SELECT 'refuse-count';" "$T/stdin" \
    && grep -q ':nadded::int + :nalready::int + :nrevived::int = :nwant::int' "$T/stdin" \
    && ! grep -qiE '\b(delete|drop|truncate|alter)\b' "$T/stdin"
}

in_orc 'do_spl_channel_agent_add_op' "${base[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && sql_shape \
  && grep -q '\[tenant=t1\]' "$T/calls.log" && grep -q '\[channel=release-notes\]' "$T/calls.log" \
  && grep -q '\[box=box-desk\]' "$T/calls.log" && grep -q '\[agents=CLE-7\]' "$T/calls.log" \
  && ! grep -q 'CLE-7' "$T/stdin" && ! grep -q 'release-notes' "$T/stdin" && ! grep -q 'box-desk' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q "OK added CLE-7 on box-desk to #release-notes in t1 ($DEV_SA)" "$T/out" \
  && ! grep -q 'already a member' "$T/out" \
  && pass "4. DRY_RUN=0: one transaction, values as -v, origin=invite, as $DEV_SA" \
  || fail "4. real: rc=$rc $(cat "$T/calls.log") $(cat "$T/out") --- $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "4. the DSN password leaked" || pass "4. the DSN password is in neither output, argv nor SQL"

printf '%s\n' 'added | CLE-7' 'added | CLE-8' >"$T/psql-two.out"
in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=release-notes AGENTS="CLE-7 CLE-8" AGENT_BOX=box-a DRY_RUN=0 \
  STUB_PSQL_FILE="$T/psql-two.out"; rc=$?
[[ $rc -eq 0 ]] && grep -q '\[agents=CLE-7 CLE-8\]' "$T/calls.log" \
  && grep -q '\[box=box-a\]' "$T/calls.log" \
  && ! grep -q 'CLE-7' "$T/stdin" && ! grep -q 'CLE-8' "$T/stdin" && ! grep -q 'box-a' "$T/stdin" \
  && pass "4. several agents and the box reach psql as -v and are absent from the SQL text" \
  || fail "4. multi: rc=$rc $(cat "$T/calls.log") $(cat "$T/stdin") $(cat "$T/out")"

# --- 5. runner messages -------------------------------------------------------
in_orc 'do_spl_channel_agent_add_op' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='already | CLE-7'; rc=$?
[[ $rc -eq 0 ]] && grep -q "OK CLE-7 is already a member of #release-notes on box-desk in t1 ($DEV_SA)" "$T/out" \
  && ! grep -q 'OK added' "$T/out" \
  && pass "5. an existing member is reported, not inserted again" \
  || fail "5. already: rc=$rc $(cat "$T/out")"

printf '%s\n' 'added | CLE-8' 'already | CLE-7' >"$T/psql-mix.out"
in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=release-notes AGENTS='CLE-7 CLE-8' DRY_RUN=0 \
  STUB_PSQL_FILE="$T/psql-mix.out"; rc=$?
[[ $rc -eq 0 ]] && grep -q "OK added CLE-8 on box-desk to #release-notes in t1 ($DEV_SA)" "$T/out" \
  && grep -q "OK CLE-7 is already a member of #release-notes on box-desk in t1 ($DEV_SA)" "$T/out" \
  && pass "5. a mix of new and existing seats is reported" \
  || fail "5. mix: rc=$rc $(cat "$T/out")"

printf '%s\n' 'already | CLE-7' 'already | CLE-8' >"$T/psql-both.out"
in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=release-notes AGENTS='CLE-7 CLE-8' DRY_RUN=0 \
  STUB_PSQL_FILE="$T/psql-both.out"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK CLE-7 CLE-8 are already members' "$T/out" \
  && pass "5. two existing seats are reported together" \
  || fail "5. both: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_agent_add_op' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-not-a-member | CLE-7' STUB_PSQL_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL not_a_member: CLE-7 is not announced on box-desk in t1' "$T/out" \
  && pass "5. an agent missing from the roster is not_a_member" \
  || fail "5. roster: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_agent_add_op' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-not-a-member | CLE-7' STUB_PSQL_RC=0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL not_a_member: CLE-7 is not announced on box-desk in t1' "$T/out" \
  && ! grep -q 'returned 0 added' "$T/out" \
  && pass "5. a refusal line is fatal even when psql exits 0" \
  || fail "5. quit-0 refusal: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_agent_add_op' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-channel | release-notes' STUB_PSQL_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no channel release-notes in t1' "$T/out" \
  && pass "5. a missing channel is a refusal" || fail "5. missing channel: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_agent_add_op' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-count' STUB_PSQL_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'unexpected number of rows; rolled back' "$T/out" \
  && pass "5. a count mismatch is a rolled-back refusal" || fail "5. count: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_agent_add_op' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT=''; rc=$?
[[ $rc -ne 0 ]] && grep -q 'returned 0 added and 0 already, want 1' "$T/out" \
  && pass "5. psql output with neither added nor already is a refusal" \
  || fail "5. empty result: rc=$rc $(cat "$T/out")"

# --- 6. ALLOW_DEFAULT_CHANNEL=1: a default channel is seated like the hub does --------
in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=lobby AGENTS=CLE-7 ALLOW_DEFAULT_CHANNEL=1 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '\[allowdef=1\]' "$T/calls.log" && grep -q '\[channel=lobby\]' "$T/calls.log" \
  && grep -q "INSERT INTO channels (tenant_id, channel_id, name, created_by, members_open_invite)" "$T/stdin" \
  && pass "6. ALLOW_DEFAULT_CHANNEL=1 seats #lobby, seeding its row first" || fail "6. lobby: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=general AGENTS=CLE-7 ALLOW_DEFAULT_CHANNEL=1 DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '\[channel=lobby\]' "$T/calls.log" && pass "6. ...and #general is #lobby" || fail "6. general: $(cat "$T/out")"
for ch in tasks issues; do
  in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=$ch AGENTS=CLE-7 ALLOW_DEFAULT_CHANNEL=1 DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "6. #$ch stays refused with ALLOW_DEFAULT_CHANNEL=1" || fail "6. #$ch accepted"
done
in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=lobby AGENTS=CLE-7 ALLOW_DEFAULT_CHANNEL=yes DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "6. ALLOW_DEFAULT_CHANNEL=yes is refused" || fail "6. bad flag accepted"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
