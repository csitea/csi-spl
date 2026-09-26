#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_channel_member_add stays offline on DRY_RUN and on bad
#          input, and a real run sends one transaction whose values are psql
#          variables. gcloud and psql are stubbed (an absent call is absent).
#   1. DRY_RUN (the default) prints the plan and calls no cloud. EMAIL is
#      lower-cased in the plan.
#   2. bad input, including a default channel, is refused before any gcloud
#      or psql call, including a value that would splice into SQL.
#   3. DRY_RUN=0 with no project SA key never reaches psql.
#   4. DRY_RUN=0 runs as the env SA. The SQL inserts channel_humans with
#      added_by='operator' ON CONFLICT DO NOTHING, requires a tenant member
#      and a live channel, and sets app.tenant_id. The human id, the email
#      and the channel are -v values, not text in the script.
#   5. the runner says so when the human is already a member, and refuses a
#      non-member, a missing channel, a human-count or a count mismatch.
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
  printf '%s\n' 'added | t1 | release-notes | HUM-4 | operator'
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

FUNC="$PROJ_ROOT/src/bash/run/spl-channel-member-add.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
sqlbody=$(awk 'index($0, "<<'\''SQL'\''") {p=1; next} $0=="SQL" {p=0} p' "$FUNC")
[[ -n "$sqlbody" ]] && ! grep -q '\$' <<<"$sqlbody" \
  && pass "0. the SQL heredoc has no shell expansion" \
  || fail "0. the SQL heredoc is empty or expanded by the shell"

# --- 1. DRY_RUN plan, no cloud ------------------------------------------------
in_orc 'do_spl_channel_member_add' TENANT_ID=t1 CHANNEL=release-notes HUMAN_ID=HUM-4; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would add HUM-4 to #release-notes in t1 (added_by=operator)' "$T/out" \
  && grep -q 'on csi-spl-dev:' "$T/out" \
  && grep -q 'Re-run with DRY_RUN=0' "$T/out" \
  && pass "1. HUMAN_ID DRY_RUN (default): plan, no cloud" \
  || fail "1. human dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

in_orc 'do_spl_channel_member_add' TENANT_ID=t1 CHANNEL=release-notes EMAIL=Owner@Example.COM DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would add owner@example.com to #release-notes in t1 (added_by=operator)' "$T/out" \
  && ! grep -q 'Owner@Example.COM' "$T/out" \
  && pass "1. EMAIL DRY_RUN: lower-cased, no cloud" \
  || fail "1. email dry: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_member_add' ENV=prd TENANT_ID=t1 CHANNEL=release-notes HUMAN_ID=HUM-4 DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'on csi-spl-prd:' "$T/out" \
  && pass "1. prd DRY_RUN names the prd connection and calls no cloud" \
  || fail "1. prd dry: rc=$rc $(cat "$T/out")"

# --- 2. bad input, before any call --------------------------------------------
base=(TENANT_ID=t1 CHANNEL=release-notes HUMAN_ID=HUM-4)
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_channel_member_add' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. $label refused before any call" || fail "2. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "missing TENANT_ID" CHANNEL=release-notes HUMAN_ID=HUM-4 DRY_RUN=0
refuse "bad tenant slug" TENANT_ID=T_1 CHANNEL=release-notes HUMAN_ID=HUM-4 DRY_RUN=0
refuse "missing CHANNEL" TENANT_ID=t1 HUMAN_ID=HUM-4 DRY_RUN=0
refuse "bad channel id" TENANT_ID=t1 CHANNEL='Rel Notes' HUMAN_ID=HUM-4 DRY_RUN=0
refuse "default lobby" TENANT_ID=t1 CHANNEL=lobby HUMAN_ID=HUM-4 DRY_RUN=0
refuse "default alerts" TENANT_ID=t1 CHANNEL=alerts HUMAN_ID=HUM-4 DRY_RUN=0
refuse "default feedback" TENANT_ID=t1 CHANNEL=feedback HUMAN_ID=HUM-4 DRY_RUN=0
refuse "default tasks" TENANT_ID=t1 CHANNEL=tasks HUMAN_ID=HUM-4 DRY_RUN=0
refuse "general alias" TENANT_ID=t1 CHANNEL=general HUMAN_ID=HUM-4 DRY_RUN=0
refuse "reserved issues" TENANT_ID=t1 CHANNEL=issues HUMAN_ID=HUM-4 DRY_RUN=0
refuse "neither HUMAN_ID nor EMAIL" TENANT_ID=t1 CHANNEL=release-notes DRY_RUN=0
refuse "both HUMAN_ID and EMAIL" TENANT_ID=t1 CHANNEL=release-notes HUMAN_ID=HUM-4 EMAIL=a@example.com DRY_RUN=0
refuse "lower-case HUMAN_ID" TENANT_ID=t1 CHANNEL=release-notes HUMAN_ID=hum-4 DRY_RUN=0
refuse "agent id as HUMAN_ID" TENANT_ID=t1 CHANNEL=release-notes HUMAN_ID=CLE-7 DRY_RUN=0
refuse "injected HUMAN_ID" TENANT_ID=t1 CHANNEL=release-notes "HUMAN_ID=HUM-4' or '1'='1" DRY_RUN=0
refuse "EMAIL that is not an email" TENANT_ID=t1 CHANNEL=release-notes EMAIL=nope DRY_RUN=0
refuse "EMAIL with a space" TENANT_ID=t1 CHANNEL=release-notes EMAIL='a b@example.com' DRY_RUN=0
refuse "DRY_RUN=2" "${base[@]}" DRY_RUN=2
in_orc 'do_spl_channel_member_add' ENV=stg "${base[@]}" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "2. ENV=stg refused before any call" || fail "2. ENV=stg: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_channel_member_add' TENANT_ID=t1 CHANNEL=general HUMAN_ID=HUM-4 DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && grep -q '#general is #lobby, a default channel' "$T/out" \
  && pass "2. general is refused as the lobby alias" || fail "2. general text: rc=$rc $(cat "$T/out")"

# --- 3. no project SA key -----------------------------------------------------
in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "3. no SA key: refused, no proxy, no psql" || fail "3. no key: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 4. the transaction -------------------------------------------------------
sql_shape() {
  grep -qx 'BEGIN;' "$T/stdin" && grep -qx 'COMMIT;' "$T/stdin" \
    && grep -qx "SET LOCAL app.tenant_id = :'tenant';" "$T/stdin" \
    && grep -q 'INSERT INTO channel_humans (tenant_id, channel_id, human_id, added_by)' "$T/stdin" \
    && grep -q "VALUES (:'tenant', :'channel', :'hid', 'operator')" "$T/stdin" \
    && grep -q 'ON CONFLICT (tenant_id, channel_id, human_id) DO NOTHING' "$T/stdin" \
    && grep -q 'count(DISTINCT human_id)' "$T/stdin" \
    && grep -q 'FROM human_identities WHERE email = :'"'"'email'"'"'' "$T/stdin" \
    && grep -q 'FROM tenant_memberships' "$T/stdin" \
    && grep -q 'deleted_at IS NULL' "$T/stdin" \
    && grep -q "'lobby', 'alerts', 'feedback', 'tasks', 'issues', 'general'" "$T/stdin" \
    && grep -q "format('refuse-human | %s'" "$T/stdin" \
    && grep -q "format('refuse-missing-human | %s'" "$T/stdin" \
    && grep -q "format('refuse-not-a-member | %s'" "$T/stdin" \
    && grep -q "format('refuse-channel | %s'" "$T/stdin" \
    && grep -q "format('refuse-public | %s'" "$T/stdin" \
    && grep -q "format('already | %s'" "$T/stdin" \
    && grep -q "format('added | %s | %s | %s | operator'" "$T/stdin" \
    && grep -qx "SELECT 'refuse-count';" "$T/stdin" \
    && ! grep -qiE '\b(delete|drop|truncate|alter)\b' "$T/stdin"
}

in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && sql_shape \
  && grep -q '\[tenant=t1\]' "$T/calls.log" && grep -q '\[human=HUM-4\]' "$T/calls.log" \
  && grep -q '\[email=\]' "$T/calls.log" && grep -q '\[channel=release-notes\]' "$T/calls.log" \
  && ! grep -q 'HUM-4' "$T/stdin" && ! grep -q 'release-notes' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q "OK added HUM-4 to #release-notes in t1 ($DEV_SA):" "$T/out" \
  && grep -q 'added | t1 | release-notes | HUM-4 | operator' "$T/out" \
  && ! grep -q 'already a member' "$T/out" \
  && pass "4. HUMAN_ID DRY_RUN=0: one transaction, values as -v, added_by=operator, as $DEV_SA" \
  || fail "4. human real: rc=$rc $(cat "$T/calls.log") $(cat "$T/out") --- $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "4. the DSN password leaked" || pass "4. the DSN password is in neither output, argv nor SQL"

in_orc 'do_spl_channel_member_add' TENANT_ID=t1 CHANNEL=release-notes EMAIL="o'wner@example.com" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "\[email=o'wner@example.com\]" "$T/calls.log" \
  && grep -q '\[human=\]' "$T/calls.log" && grep -q '\[channel=release-notes\]' "$T/calls.log" \
  && ! grep -q "o'wner@example.com" "$T/stdin" && ! grep -q 'HUM-' "$T/stdin" \
  && pass "4. EMAIL reaches psql as -v (quote included) and is absent from the SQL text" \
  || fail "4. email real: rc=$rc $(cat "$T/calls.log") $(cat "$T/stdin")"

# --- 5. runner messages -------------------------------------------------------
in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT='already | HUM-4'; rc=$?
[[ $rc -eq 0 ]] && grep -q "OK HUM-4 is already a member of #release-notes in t1 ($DEV_SA)" "$T/out" \
  && ! grep -q 'OK added' "$T/out" \
  && pass "5. an existing member is reported, not inserted again" \
  || fail "5. already: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_member_add' TENANT_ID=t1 CHANNEL=release-notes EMAIL=person@example.com DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-human | 2' STUB_PSQL_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL email person@example.com matches 2 human(s) in human_identities; want exactly one' "$T/out" \
  && pass "5. two humans for one email is a refusal" || fail "5. two humans: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-missing-human | HUM-4' STUB_PSQL_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL human HUM-4 is not in humans' "$T/out" \
  && pass "5. a HUMAN_ID missing from humans is a refusal" || fail "5. missing human: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-not-a-member | HUM-4' STUB_PSQL_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL not_a_member: HUM-4 is not a member of t1' "$T/out" \
  && pass "5. a human who is not a tenant member is not_a_member" \
  || fail "5. not a member: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-not-a-member | HUM-4' STUB_PSQL_RC=0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL not_a_member: HUM-4 is not a member of t1' "$T/out" \
  && ! grep -q 'no single membership result' "$T/out" \
  && pass "5. a refusal line is fatal even when psql exits 0" \
  || fail "5. quit-0 refusal: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-channel | release-notes' STUB_PSQL_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no channel release-notes in t1' "$T/out" \
  && pass "5. a missing channel is a refusal" || fail "5. missing channel: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0 \
  STUB_PSQL_OUT='refuse-count' STUB_PSQL_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'unexpected number of rows; rolled back' "$T/out" \
  && pass "5. a count mismatch is a rolled-back refusal" || fail "5. count: rc=$rc $(cat "$T/out")"

in_orc 'do_spl_channel_member_add' "${base[@]}" DRY_RUN=0 STUB_PSQL_OUT=''; rc=$?
[[ $rc -ne 0 ]] && grep -q 'no single membership result' "$T/out" \
  && pass "5. psql output with neither added nor already is a refusal" \
  || fail "5. empty result: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
