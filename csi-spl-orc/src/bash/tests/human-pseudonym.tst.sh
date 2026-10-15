#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_human_pseudonym stays offline on DRY_RUN and on bad input,
#          and a real run sets humans.display_name and drops the picture
#          (avatar_file_id, idp_avatar_file_id NULL, avatar_own true) in one
#          transaction, values as psql variables. EMAIL resolves to exactly
#          one human; exactly one row, or the script rolls back. The output
#          never names the email. gcloud and psql are stubbed; fake humans.
#          Red controls: the statement check fails on a copy without the
#          avatar clear, and with the action file missing.
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

FUNC="$PROJ_ROOT/src/bash/run/spl-human-pseudonym.func.sh"
[[ -f "$FUNC" ]] || { echo "FAIL: no $FUNC"; exit 1; }
DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
DSN_PW="pw$RANDOM$RANDOM"
FAKE_EMAIL=fake.person@example.com
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
if [[ -n "${STUB_PSQL_OUT+x}" ]]; then
  printf '%s\n' "$STUB_PSQL_OUT"
else
  printf '%s\n' 'set | HUM-4 | Ab Cd'
fi
exit "${STUB_PSQL_RC:-0}"
EOF
chmod +x "$T/stub/"*

# in_orc <snippet> [VAR=val...]: run the snippet with every orc function
# sourced, then $EXTRA_FUNC (a mutant) if set; gcloud, psql and the proxy stubbed.
in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u HUMAN_ID -u EMAIL \
    -u DISPLAY_NAME -u STUB_PSQL_OUT -u STUB_PSQL_RC -u EXTRA_FUNC \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh ${EXTRA_FUNC:-}; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
grep -q '^# @description' "$FUNC" && grep -q '^do_spl_human_pseudonym() {' "$FUNC" \
  && pass "0. @description block, csi-rel name" || fail "0. description or name"
LC_ALL=C grep -q -P '[\x80-\xff]' "$FUNC" && fail "0. non-ASCII byte in the action" || pass "0. the action is ASCII"

# --- 1. DRY_RUN ----------------------------------------------------------------
in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME='  Ab Cd  '; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q "DRY_RUN would set the display name of HUM-4 to 'Ab Cd' and drop the picture on csi-spl-dev:" "$T/out" \
  && pass "1. DRY_RUN (default): trimmed plan, no cloud" \
  || fail "1. dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
in_orc 'do_spl_human_pseudonym' ENV=prd EMAIL="$FAKE_EMAIL" DISPLAY_NAME='Ab Cd' DRY_RUN=1; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'on csi-spl-prd:' "$T/out" \
  && ! grep -qi "$FAKE_EMAIL" "$T/out" \
  && pass "1. prd DRY_RUN by EMAIL: no cloud, the email is not printed" \
  || fail "1. prd dry: rc=$rc $(cat "$T/out")"

# --- 2. refusals --------------------------------------------------------------
long=$(printf 'a%.0s' $(seq 201))
max=$(printf 'a%.0s' $(seq 200))
refuse() {
  local label="$1"; shift
  in_orc 'do_spl_human_pseudonym' "$@"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && ! grep -qi "$FAKE_EMAIL" "$T/out" \
    && pass "2. $label refused before any call" || fail "2. $label: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
}
refuse "neither HUMAN_ID nor EMAIL" DISPLAY_NAME='Ab Cd' DRY_RUN=0
refuse "both HUMAN_ID and EMAIL" HUMAN_ID=HUM-4 EMAIL="$FAKE_EMAIL" DISPLAY_NAME='Ab Cd' DRY_RUN=0
refuse "injected HUMAN_ID" "HUMAN_ID=HUM-4' or '1'='1" DISPLAY_NAME='Ab Cd' DRY_RUN=0
refuse "bad EMAIL" EMAIL=not-an-email DISPLAY_NAME='Ab Cd' DRY_RUN=0
refuse "missing DISPLAY_NAME" HUMAN_ID=HUM-4 DRY_RUN=0
refuse "empty DISPLAY_NAME" HUMAN_ID=HUM-4 DISPLAY_NAME= DRY_RUN=0
refuse "blank DISPLAY_NAME" HUMAN_ID=HUM-4 'DISPLAY_NAME=   ' DRY_RUN=0
refuse "201-char DISPLAY_NAME" HUMAN_ID=HUM-4 DISPLAY_NAME="$long" DRY_RUN=0
refuse "control char in DISPLAY_NAME" HUMAN_ID=HUM-4 DISPLAY_NAME=$'Ab\tCd' DRY_RUN=0
refuse "direction override in DISPLAY_NAME" HUMAN_ID=HUM-4 DISPLAY_NAME="$(printf 'Ab%bCd' '\u202e')" DRY_RUN=0
refuse "line separator in DISPLAY_NAME" HUMAN_ID=HUM-4 DISPLAY_NAME="$(printf 'Ab%bCd' '\u2028')" DRY_RUN=0
refuse "invalid UTF-8 DISPLAY_NAME" HUMAN_ID=HUM-4 DISPLAY_NAME=$'Ab\xffCd' DRY_RUN=0
refuse "DRY_RUN=2" HUMAN_ID=HUM-4 DISPLAY_NAME='Ab Cd' DRY_RUN=2
refuse "ENV=stg" ENV=stg HUMAN_ID=HUM-4 DISPLAY_NAME='Ab Cd' DRY_RUN=0
in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME="$max"; rc=$?
[[ $rc -eq 0 ]] && pass "2. a 200-char name is accepted" || fail "2. 200 chars: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME="$(printf '\303\204%.0s' $(seq 200))"; rc=$?
[[ $rc -eq 0 ]] && pass "2. 200 two-byte characters count as 200, not 400" || fail "2. runes: rc=$rc $(cat "$T/out")"

# --- 3. no key ----------------------------------------------------------------
in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME='Ab Cd' DRY_RUN=0 GCP_SA_KEY_FILE="$T/nokey.json"; rc=$?
[[ $rc -ne 0 ]] && ! grep -qE '^(psql|proxy-start)' "$T/calls.log" \
  && pass "3. no SA key: refused, no proxy, no psql" || fail "3. no key: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 4. the statement (and its red control) -----------------------------------
# statement_ok: the last run sent one transaction that sets the name and drops
# the picture, values as -v only.
statement_ok() {
  grep -qx 'BEGIN;' "$T/stdin" && grep -qx 'COMMIT;' "$T/stdin" && grep -qx 'ROLLBACK;' "$T/stdin" \
    && grep -q "UPDATE humans SET display_name = :'name', avatar_file_id = NULL," "$T/stdin" \
    && grep -q "avatar_own = true, idp_avatar_file_id = NULL" "$T/stdin" \
    && grep -q "WHERE human_id = :'hid'" "$T/stdin" \
    && grep -q 'SELECT (:ROW_COUNT = 1)::int AS one' "$T/stdin" \
    && ! grep -q 'app.tenant_id' "$T/stdin" \
    && ! grep -qiE '\b(insert|delete|drop|truncate|alter)\b' "$T/stdin"
}
in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME='Ab Cd' DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && statement_ok \
  && grep -q '\[human=HUM-4\]' "$T/calls.log" && grep -q '\[name=Ab Cd\]' "$T/calls.log" && grep -q '\[email=\]' "$T/calls.log" \
  && ! grep -q 'HUM-4' "$T/stdin" && ! grep -q 'Ab Cd' "$T/stdin" \
  && grep -qx "proxy-start as $DEV_SA" "$T/calls.log" \
  && grep -q "OK HUM-4 | Ab Cd ($DEV_SA): display name set, picture dropped" "$T/out" \
  && pass "4. DRY_RUN=0 by HUMAN_ID: one transaction, name + picture, values as -v, as $DEV_SA" \
  || fail "4. real: rc=$rc $(cat "$T/calls.log") $(cat "$T/out") --- $(cat "$T/stdin")"
grep -qF "$DSN_PW" "$T/out" "$T/calls.log" "$T/stdin" && fail "4. the DSN password leaked" || pass "4. the DSN password is in neither output, argv nor SQL"

in_orc 'do_spl_human_pseudonym' EMAIL="FAKE.Person@Example.com" DISPLAY_NAME='Ab Cd' DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && statement_ok \
  && grep -q "\[email=$FAKE_EMAIL\]" "$T/calls.log" && grep -q '\[human=\]' "$T/calls.log" \
  && grep -q "human_identities WHERE email = :'email'" "$T/stdin" \
  && ! grep -qi "$FAKE_EMAIL" "$T/out" \
  && grep -q 'OK HUM-4 | Ab Cd' "$T/out" \
  && pass "4. DRY_RUN=0 by EMAIL: lower-cased -v email, the output names the human_id only" \
  || fail "4. by email: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

sed 's/, avatar_file_id = NULL,$/,/' "$FUNC" >"$T/mutant.func.sh"
if cmp -s "$FUNC" "$T/mutant.func.sh"; then
  fail "4. RED control: the mutant did not remove the avatar clear"
else
  in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME='Ab Cd' DRY_RUN=0 EXTRA_FUNC="$T/mutant.func.sh"
  statement_ok && fail "4. RED control: the statement check passed without the avatar clear" \
    || pass "4. RED control: the statement check fails without the avatar clear"
fi
mkdir -p "$T/noaction/src/bash/run" "$T/noaction/src/bash/tests"
cp "$0" "$T/noaction/src/bash/tests/"
bash "$T/noaction/src/bash/tests/$(basename "$0")" >"$T/noaction.out" 2>&1 \
  && fail "4. RED control: the test passed with the action file missing" \
  || pass "4. RED control: the test fails with the action file missing"

# --- 5. refusals from the database --------------------------------------------
in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME='Ab Cd' DRY_RUN=0 STUB_PSQL_OUT='refuse-count'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no humans row for HUM-4: rolled back' "$T/out" \
  && pass "5. no humans row (0 rows) is a rollback" || fail "5. zero: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_human_pseudonym' EMAIL="$FAKE_EMAIL" DISPLAY_NAME='Ab Cd' DRY_RUN=0 STUB_PSQL_OUT='refuse-human | 0'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'matches 0 human(s)' "$T/out" && ! grep -qi "$FAKE_EMAIL" "$T/out" \
  && pass "5. an EMAIL matching no human is refused" || fail "5. email 0: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_human_pseudonym' EMAIL="$FAKE_EMAIL" DISPLAY_NAME='Ab Cd' DRY_RUN=0 STUB_PSQL_OUT='refuse-human | 2'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'matches 2 human(s)' "$T/out" && ! grep -qi "$FAKE_EMAIL" "$T/out" \
  && pass "5. an EMAIL matching 2 humans is refused" || fail "5. email 2: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME='Ab Cd' DRY_RUN=0 STUB_PSQL_OUT=$'set | HUM-4 | Ab Cd\nset | HUM-5 | Ab Cd'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL 2 row(s) changed' "$T/out" \
  && pass "5. two changed rows are refused" || fail "5. two: rc=$rc $(cat "$T/out")"
in_orc 'do_spl_human_pseudonym' HUMAN_ID=HUM-4 DISPLAY_NAME='Ab Cd' DRY_RUN=0 STUB_PSQL_OUT='ERROR: boom' STUB_PSQL_RC=3; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL pseudonym update of HUM-4 failed (psql rc 3)' "$T/out" \
  && pass "5. a psql error is a failure" || fail "5. psql error: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
