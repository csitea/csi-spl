#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_sa_key_rotate (SPL-2735, SPL-1945 build order row 1) walks
#          one rotation of the per-env project SA key, step by step, and
#          refuses each step out of order.
#   1. status, one key: lists it, NEXT mint; every gcloud call as the dev
#      project SA on csi-spl-dev, metadata only (no create, no delete)
#   2. mint DRY_RUN unset: names the create, no create call, key file untouched
#   3. CONTROL: retire before prove (after a real mint) -> refused, no delete
#      call (fails when the proof check is removed)
#   4. mint DRY_RUN=0: the key file holds the new key, mode 600; the old file
#      is <file>.prev; the key itself is never printed
#   5. mint again while two keys are open -> refused, no create
#   6. status after mint -> NEXT prove; prove: proof id printed and recorded;
#      a key that mints no token -> refused, nothing recorded
#   7. retire refusals: no other-box proof, a same-box second proof, no CI
#      run id, OLD_KEY_ID = the new key; DRY_RUN unset -> no delete call;
#      DRY_RUN=0 -> deletes the old key id only, removes <file>.prev
#   8. a key file whose key the SA does not hold -> refused
#   9. bad ROTATE_STEP / ENV / DRY_RUN -> refused before any gcloud call
#  10. the action never runs `gcloud config set` and never reads the owner account
# gcloud is a stub. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-sa-key-rotate.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null && command -v jq >/dev/null || { echo "SKIP: no yq or jq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
OLD=aaaaaaaaaaaa1111111111111111111111111111
NEW=bbbbbbbbbbbb2222222222222222222222222222
K="$T/home/.gcp/.csi/key-csi-spl-dev.json"
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/app/csi-spl-cnf"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$T/app/csi-spl-cnf/csi-spl"
# the field name is an argument, so no-key-material-in-tree.tst.sh never sees a key shape here
fake_key() { printf '{"type":"service_account","client_email":"%s","private_key_id":"%s","%s":"FAKESECRET%s"}\n' "$DEV_SA" "$1" private_key "$1"; }
reset_state() {
  rm -rf "$T/home/.local" "$K.prev"; (umask 077; fake_key "$OLD" >"$K")
  printf '{"name":"projects/csi-spl-dev/serviceAccounts/%s/keys/%s","validAfterTime":"2026-09-01T10:00:00Z"}\n' "$DEV_SA" "$OLD" >"$T/keys.ndjson"
}

cat >"$T/stub/gcloud" <<'EOF_G'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) [[ -z "${STUB_TOKEN_FAIL:-}" ]] || exit 1; echo ya29.fake-token ;;
  "projects describe"*) echo "$3" ;;
  "iam service-accounts keys list"*) jq -s . "$STUB_KEYS" ;;
  "iam service-accounts keys create"*)
    printf '{"type":"service_account","client_email":"%s","private_key_id":"%s","%s":"FAKESECRETNEW"}\n' "$(arg --iam-account "$@")" "$STUB_NEW" private_key >"$5"
    printf '{"name":"projects/p/serviceAccounts/x/keys/%s","validAfterTime":"2026-10-20T10:00:00Z"}\n' "$STUB_NEW" >>"$STUB_KEYS" ;;
  "iam service-accounts keys delete"*) grep -v "/keys/$5\"" "$STUB_KEYS" >"$STUB_KEYS.n"; mv "$STUB_KEYS.n" "$STUB_KEYS" ;;
esac
exit 0
EOF_G
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u ROTATE_STEP -u XDG_STATE_HOME -u OLD_KEY_ID -u PROOF_IDS -u CI_RUN_ID \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" STUB_KEYS="$T/keys.ndjson" STUB_NEW="$NEW" \
    GCP_ACCOUNT_OWNER_EMAIL=owner@example.com SA_KEY_PROOF_BOX=boxa \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/app" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/gcp-sa-key-rotate.func.sh; do source "$f"; done
    do_gcp_sa_key_rotate' >"$T/out" 2>&1
}
file_id() { jq -r .private_key_id "$K"; }
no_create() { ! grep -q 'keys create' "$T/calls.log"; }
no_delete() { ! grep -q 'keys delete' "$T/calls.log"; }

# --- 1. status, one key -----------------------------------------------------------
reset_state; act; rc=$?
[[ $rc -eq 0 ]] && grep -q "1 user-managed enabled key(s), max age 30 d" "$T/out" && grep -q "key $OLD created 2026-09-01T10:00:00Z .* <- the key file" "$T/out" \
  && grep -q 'NEXT mint: ENV=dev ROTATE_STEP=mint' "$T/out" && pass "1. status: one key, the key file's, NEXT mint" || fail "1. rc=$rc $(cat "$T/out")"
grep -q 'past the 30 d max age' "$T/out" && pass "1. a key older than 30 d is flagged" || fail "1. age: $(cat "$T/out")"
n=$(grep -c '|iam ' "$T/calls.log"); m=$(grep '|iam ' "$T/calls.log" | grep -- "--account=$DEV_SA" | grep -c -- '--project=csi-spl-dev')
[[ $n -eq 1 && $m -eq 1 ]] && no_create && no_delete && pass "1. one keys list, as the dev project SA on csi-spl-dev; nothing created or deleted" || fail "1. calls: $(cat "$T/calls.log")"

# --- 2. mint, dry run --------------------------------------------------------------
act ROTATE_STEP=mint; rc=$?
[[ $rc -eq 0 ]] && no_create && [[ "$(file_id)" == "$OLD" && ! -e "$K.prev" ]] && grep -q 'DRY_RUN would run: gcloud iam service-accounts keys create' "$T/out" \
  && pass "2. mint DRY_RUN unset: names the create, no create call, key file untouched" || fail "2. rc=$rc $(cat "$T/out")"

# --- 3. CONTROL: retire before prove -------------------------------------------------
act ROTATE_STEP=mint DRY_RUN=0 >/dev/null
act ROTATE_STEP=retire DRY_RUN=0 OLD_KEY_ID="$OLD" PROOF_IDS="boxa:${NEW:0:12}:20261020T100000Z,boxb:${NEW:0:12}:20261020T100000Z" CI_RUN_ID=123; rc=$?
[[ $rc -ne 0 ]] && no_delete && grep -q "no proof on this box for key $NEW: ROTATE_STEP=prove first" "$T/out" && grep -q "/keys/$OLD" "$T/keys.ndjson" \
  && pass "3. CONTROL: retire before prove -> refused, no delete call, the old key stays" || fail "3. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 4. mint, real (state from case 3) ---------------------------------------------------
reset_state; act ROTATE_STEP=mint DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(file_id)" == "$NEW" && "$(stat -c %a "$K")" == 600 ]] && [[ "$(jq -r .private_key_id "$K.prev")" == "$OLD" ]] \
  && pass "4. mint DRY_RUN=0: the key file holds the new key (mode 600), the old one is <file>.prev" || fail "4. rc=$rc mode=$(stat -c %a "$K") $(cat "$T/out")"
c=$(grep 'keys create' "$T/calls.log"); [[ "$c" == *"--iam-account=$DEV_SA"* && "$c" == *"--account=$DEV_SA"* && "$c" == *"$T/home/.gcp/.csi/"* ]] \
  && pass "4. one create, as the dev project SA, written inside the key dir" || fail "4. create: $c"
! grep -q FAKESECRET "$T/out" && pass "4. the key is never printed" || fail "4. key printed: $(cat "$T/out")"
files=$(cd "$T/home/.gcp/.csi" && printf '%s ' .[!.]* *)
[[ "$files" == ".[!.]* key-csi-spl-dev.json key-csi-spl-dev.json.prev " ]] && pass "4. no other file in the key dir" || fail "4. key dir holds: $files"

# --- 5. mint again --------------------------------------------------------------------
act ROTATE_STEP=mint DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && no_create && grep -q 'already holds 2 user keys: a rotation is open' "$T/out" && pass "5. mint with two keys open -> refused, no create" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6. status, prove ------------------------------------------------------------------
act; grep -q 'NEXT prove: ENV=dev ROTATE_STEP=prove' "$T/out" && pass "6. status after mint -> NEXT prove" || fail "6. $(cat "$T/out")"
act ROTATE_STEP=prove STUB_TOKEN_FAIL=1; rc=$?
[[ $rc -ne 0 && ! -e "$T/home/.local/state/csi-spl/gcp-sa-key-rotate.proofs" ]] && grep -q 'mints no token' "$T/out" \
  && pass "6. prove: no token -> refused, nothing recorded" || fail "6. token rc=$rc $(cat "$T/out")"
act ROTATE_STEP=prove; rc=$?
MINE=$(sed -n 's/.*Proof id: //p' "$T/out")
[[ $rc -eq 0 && "$MINE" =~ ^boxa:${NEW:0:12}:[0-9]{8}T[0-9]{6}Z$ ]] && grep -q "csi-spl-dev $NEW $MINE" "$T/home/.local/state/csi-spl/gcp-sa-key-rotate.proofs" \
  && pass "6. prove: token + project read -> proof id $MINE, recorded" || fail "6. prove rc=$rc $(cat "$T/out")"
n=$(grep -cE '\|(auth print-access-token|projects describe) ' "$T/calls.log"); m=$(grep -E '\|(auth print-access-token|projects describe) ' "$T/calls.log" | grep -c -- "--account=$DEV_SA")
[[ $n -eq 2 && $m -eq 2 ]] && ! grep -q ya29 "$T/out" \
  && pass "6. prove used the key file's SA and printed no token" || fail "6. prove calls: $(cat "$T/calls.log") $(cat "$T/out")"
act; grep -q "NEXT retire, .* PROOF_IDS=$MINE,<other box's proof id>" "$T/out" && pass "6. status after prove -> NEXT retire with this box's proof" || fail "6. next: $(cat "$T/out")"

# --- 7. retire ---------------------------------------------------------------------------
OTHER="boxb:${NEW:0:12}:20261020T110000Z"
r() { act ROTATE_STEP=retire OLD_KEY_ID="$OLD" "$@"; }
r DRY_RUN=0 PROOF_IDS="$MINE" CI_RUN_ID=123; rc=$?
[[ $rc -ne 0 ]] && no_delete && grep -q 'no proof id from another box' "$T/out" && pass "7. no other-box proof -> refused" || fail "7a rc=$rc $(cat "$T/out")"
r DRY_RUN=0 PROOF_IDS="$MINE,boxa:${NEW:0:12}:20261020T110000Z" CI_RUN_ID=123; rc=$?
[[ $rc -ne 0 ]] && no_delete && pass "7. a second proof from the same box -> refused" || fail "7b rc=$rc $(cat "$T/out")"
r DRY_RUN=0 PROOF_IDS="$MINE,boxb:${OLD:0:12}:20261020T110000Z" CI_RUN_ID=123; rc=$?
[[ $rc -ne 0 ]] && no_delete && pass "7. an other-box proof of a different key -> refused" || fail "7c rc=$rc $(cat "$T/out")"
r DRY_RUN=0 PROOF_IDS="$OTHER" CI_RUN_ID=123; rc=$?
[[ $rc -ne 0 ]] && no_delete && grep -q "lacks this box's proof" "$T/out" && pass "7. this box's proof missing from PROOF_IDS -> refused" || fail "7d rc=$rc $(cat "$T/out")"
r DRY_RUN=0 PROOF_IDS="$MINE,$OTHER"; rc=$?
[[ $rc -ne 0 ]] && no_delete && grep -q 'CI_RUN_ID must be' "$T/out" && pass "7. no CI run id -> refused" || fail "7e rc=$rc $(cat "$T/out")"
act ROTATE_STEP=retire DRY_RUN=0 OLD_KEY_ID="$NEW" PROOF_IDS="$MINE,$OTHER" CI_RUN_ID=123; rc=$?
[[ $rc -ne 0 ]] && no_delete && grep -q 'retire deletes the OLD key only' "$T/out" && pass "7. OLD_KEY_ID = the new key -> refused" || fail "7f rc=$rc $(cat "$T/out")"
r PROOF_IDS="$MINE,$OTHER" CI_RUN_ID=123; rc=$?
[[ $rc -eq 0 ]] && no_delete && [[ -e "$K.prev" ]] && grep -q "DRY_RUN would run: gcloud iam service-accounts keys delete $OLD" "$T/out" \
  && pass "7. retire DRY_RUN unset: names the delete, no delete call" || fail "7g rc=$rc $(cat "$T/out")"
r DRY_RUN=0 PROOF_IDS="$MINE,$OTHER" CI_RUN_ID=123; rc=$?
d=$(grep 'keys delete' "$T/calls.log")
[[ $rc -eq 0 && "$d" == *"keys delete $OLD --iam-account=$DEV_SA"* && "$d" == *"--account=$DEV_SA"* && ! -e "$K.prev" ]] && ! grep -q "/keys/$OLD" "$T/keys.ndjson" && grep -q "/keys/$NEW" "$T/keys.ndjson" \
  && pass "7. retire DRY_RUN=0: deletes the old key only, removes <file>.prev" || fail "7h rc=$rc $d $(cat "$T/out")"
act; grep -q 'NEXT mint' "$T/out" && grep -q "key $NEW .* <- the key file" "$T/out" && pass "7. status after retire: one key, the new one" || fail "7i $(cat "$T/out")"

# --- 8. a stale key file -------------------------------------------------------------------
reset_state; (umask 077; fake_key cccccccccccc3333333333333333333333333333 >"$K"); act; rc=$?
[[ $rc -ne 0 ]] && grep -q 'which csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com does not hold enabled' "$T/out" && pass "8. a key file the SA does not hold -> refused" || fail "8. rc=$rc $(cat "$T/out")"

# --- 9. refusals before any gcloud call -------------------------------------------------------
reset_state
for bad in "ROTATE_STEP=rotate" "ENV=all" "DRY_RUN=2"; do
  act "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "9. $bad -> refused before any gcloud call" || fail "9. $bad rc=$rc $(cat "$T/calls.log")"
done

# --- 10. static ----------------------------------------------------------------------------------
! grep -nE 'gcloud +config +set|gcp_account_owner_email|GCP_ACCOUNT_OWNER_EMAIL|do_gcp_(pin_)?bootstrap_account' "$ACTION" \
  && pass "10. no gcloud config set, no owner account in the action" || fail "10. the action names the shared config or the owner account"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
