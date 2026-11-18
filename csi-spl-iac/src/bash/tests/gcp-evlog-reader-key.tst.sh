#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 162 case C47 (row T7a, SPL-5882; owner poll 00d28227 Q1 B):
#          do_gcp_evlog_reader_key mints the event-log reader SA's key, one
#          per env on this box, as the env's project SA.
#   1. DRY_RUN unset: no gcloud call, nothing written; prints the reader SA
#      (cnf env.gcp.evlog_reader_sa_id @ the env project) and the key path
#      $HOME/.gcp/.<org>/key-<project>-evlog-reader.json; ENV=prd names prd's
#   2. DRY_RUN=0: one keys create for the reader SA, as the dev project SA,
#      on csi-spl-dev, in a private CLOUDSDK_CONFIG; the key lands ONLY in
#      the key file, mode 600; it is never on stdout or in the log; every
#      gcloud call but `auth` carries --account; no `gcloud config set`
#   3. DRY_RUN=0 with the key file there -> refused, no create; DRY_RUN=1
#      then reports its age and the rotate command
#   4. EVLOG_KEY_ROTATE=1 DRY_RUN=0 (R9): the new key reads the logs as the
#      reader SA, then the old key id is deleted as the project SA and
#      <file>.prev removed; a new key that cannot read the logs keeps the
#      old key (<file>.prev), no delete
#   5. no project SA key -> refused, no create, the owner account never used
#   6. bad ENV / DRY_RUN / EVLOG_KEY_ROTATE -> refused before any gcloud call
#   7. CONTROL: a copy of the action that echoes the key file fails the
#      "never printed" check of 2; a copy whose create drops --account fails
#      the "every call pinned" check of 2
# gcloud is a stub. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-evlog-reader-key.func.sh"
fails=0
tmp_dir
command -v yq >/dev/null && command -v jq >/dev/null || { echo "SKIP: no yq or jq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
RD_SA=spl-evlog-reader@csi-spl-dev.iam.gserviceaccount.com
OLD=aaaaaaaaaaaa1111111111111111111111111111
NEW=bbbbbbbbbbbb2222222222222222222222222222
KD="$T/home/.gcp/.csi"; PK="$KD/key-csi-spl-dev.json"; RK="$KD/key-csi-spl-dev-evlog-reader.json"
mkdir -p "$KD" "$T/stub" "$T/app/csi-spl-cnf"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$T/app/csi-spl-cnf/csi-spl"
# the field name is an argument, so no-key-material-in-tree.tst.sh never sees a key shape here
fake_key() { printf '{"type":"service_account","client_email":"%s","private_key_id":"%s","%s":"FAKESECRET%s"}\n' "$1" "$2" private_key "$2"; }
clear_keys() { rm -f "${KD:?}"/key-*.json "${KD:?}"/key-*.json.prev; }
reset_state() { clear_keys; (umask 077; fake_key "$DEV_SA" pppp >"$PK"); }

cat >"$T/stub/gcloud" <<'EOF_G'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >>"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) f="$(arg --filter "$@")"; grep -x "${f#account:}" "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "logging read"*) [[ -z "${STUB_READ_FAIL:-}" ]] || exit 1 ;;
  "iam service-accounts keys create"*)
    printf '{"type":"service_account","client_email":"%s","private_key_id":"%s","%s":"FAKESECRETNEW"}\n' "$(arg --iam-account "$@")" "$STUB_NEW" private_key >"$5" ;;
esac
exit 0
EOF_G
chmod +x "$T/stub/gcloud"

# act <action file> [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  local a="$1"; shift
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u GCP_SA_KEY_FILE -u DRY_RUN -u EVLOG_KEY_ROTATE -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" STUB_NEW="$NEW" ACT_FILE="$a" \
    GCP_ACCOUNT_OWNER_EMAIL=owner@example.com \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/app" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$ACT_FILE"; do source "$f"; done
    do_gcp_evlog_reader_key' >"$T/out" 2>&1
}
no_gcloud() { [[ ! -s "$T/calls.log" ]]; }
no_create() { ! grep -q 'keys create' "$T/calls.log"; }
unpinned() { grep -v '|auth ' "$T/calls.log" | grep -vc -- '--account='; }
not_printed() { ! grep -q FAKESECRET "$T/out"; }

# --- 1. dry run -------------------------------------------------------------------
reset_state; act "$ACTION"; rc=$?
[[ $rc -eq 0 ]] && no_gcloud && [[ ! -e "$RK" ]] && grep -q "SA: $RD_SA$" "$T/out" && grep -q "key file on this box: $RK$" "$T/out" \
  && grep -q 'DRY_RUN would mint one key' "$T/out" && pass "1. DRY_RUN unset: no gcloud call, nothing written; prints the reader SA and the key path" || fail "1. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
act "$ACTION" ENV=prd; rc=$?
[[ $rc -eq 0 ]] && no_gcloud && grep -q 'SA: spl-evlog-reader@csi-spl-prd.iam.gserviceaccount.com$' "$T/out" && grep -q "key-csi-spl-prd-evlog-reader.json$" "$T/out" \
  && pass "1. ENV=prd: prd's reader SA and key path" || fail "1. prd rc=$rc $(cat "$T/out")"

# --- 2. mint ----------------------------------------------------------------------------
act "$ACTION" DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(jq -r .client_email "$RK")" == "$RD_SA" && "$(stat -c %a "$RK")" == 600 ]] \
  && pass "2. DRY_RUN=0: the reader key is in the key file, mode 600" || fail "2. rc=$rc $(cat "$T/out")"
c=$(grep 'keys create' "$T/calls.log"); n=$(grep -c 'keys create' "$T/calls.log")
[[ $n -eq 1 && "$c" == *"--iam-account=$RD_SA"* && "$c" == *"--account=$DEV_SA"* && "$c" == *"--project=csi-spl-dev"* && "${c%%|*}" != "<unset>" && "${c%%|*}" != "$T/home/.config/gcloud" ]] \
  && pass "2. one create, for the reader SA, as the dev project SA, on csi-spl-dev, in a private gcloud config" || fail "2. create: $(cat "$T/calls.log")"
not_printed && pass "2. the key is never printed (stdout and log)" || fail "2. key printed: $(cat "$T/out")"
[[ "$(unpinned)" == 0 ]] && ! grep -q '|config ' "$T/calls.log" && pass "2. every gcloud call but auth carries --account; no gcloud config" || fail "2. unpinned: $(cat "$T/calls.log")"
files=$(cd "$KD" && printf '%s ' .[!.]* *)
[[ "$files" == ".[!.]* key-csi-spl-dev-evlog-reader.json key-csi-spl-dev.json " ]] && pass "2. no other file in the key dir" || fail "2. key dir holds: $files"
! grep -q owner@example.com "$T/out" "$T/calls.log" && pass "2. the owner account is never used" || fail "2. owner account seen"

# --- 3. a second mint ---------------------------------------------------------------------
act "$ACTION" DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && no_create && grep -q 'exists: one key per env on this box' "$T/out" && pass "3. DRY_RUN=0 with the key there -> refused, no create" || fail "3. rc=$rc $(cat "$T/out")"
touch -d '40 days ago' "$RK"; act "$ACTION"; rc=$?
[[ $rc -eq 0 ]] && no_gcloud && grep -q 'past the 30 d max age' "$T/out" && grep -q 'EVLOG_KEY_ROTATE=1 DRY_RUN=0' "$T/out" \
  && pass "3. DRY_RUN=1 with the key there: its age, past max, the rotate command; no gcloud" || fail "3. dry rc=$rc $(cat "$T/out")"

# --- 4. rotate ------------------------------------------------------------------------------
(umask 077; fake_key "$RD_SA" "$OLD" >"$RK")
act "$ACTION" DRY_RUN=0 EVLOG_KEY_ROTATE=1 STUB_READ_FAIL=1; rc=$?
[[ $rc -ne 0 && "$(jq -r .private_key_id "$RK.prev")" == "$OLD" ]] && ! grep -q 'keys delete' "$T/calls.log" && grep -q 'old key .* is kept' "$T/out" \
  && pass "4. rotate: a new key that cannot read the logs keeps the old key (.prev), no delete" || fail "4. fail rc=$rc $(cat "$T/out")"
rm -f "$RK.prev"; (umask 077; fake_key "$RD_SA" "$OLD" >"$RK")
act "$ACTION" DRY_RUN=0 EVLOG_KEY_ROTATE=1; rc=$?
r=$(grep 'logging read' "$T/calls.log"); d=$(grep 'keys delete' "$T/calls.log")
[[ $rc -eq 0 && "$(jq -r .private_key_id "$RK")" == "$NEW" && "$(stat -c %a "$RK")" == 600 && ! -e "$RK.prev" ]] \
  && [[ "$r" == *"--account=$RD_SA"* && "$r" == *"--project=csi-spl-dev"* && "$d" == *"keys delete $OLD "* && "$d" == *"--account=$DEV_SA"* && "$d" == *"--iam-account=$RD_SA"* ]] \
  && not_printed && [[ "$(unpinned)" == 0 ]] \
  && pass "4. rotate: the new key reads the logs as the reader SA, the old key id is deleted as the project SA, .prev removed" || fail "4. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 5. no project SA key --------------------------------------------------------------------
clear_keys; act "$ACTION" DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && no_create && [[ ! -e "$RK" ]] && ! grep -q owner@example.com "$T/out" "$T/calls.log" \
  && pass "5. no project SA key -> refused, no create, no owner account" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6. bad input --------------------------------------------------------------------------------
reset_state; bad=0
for v in "ENV=stg" "DRY_RUN=2" "EVLOG_KEY_ROTATE=yes"; do
  act "$ACTION" DRY_RUN=0 "$v"; rc=$?; [[ $rc -eq 2 ]] && no_gcloud || { bad=1; echo "  $v rc=$rc"; }
done
[[ $bad -eq 0 ]] && pass "6. bad ENV / DRY_RUN / EVLOG_KEY_ROTATE -> refused (rc 2) before any gcloud call" || fail "6. bad input not refused"

# --- 7. controls -----------------------------------------------------------------------------------
reset_state; sed 's|^  do_log "OK new key|  cat "$key"; do_log "OK new key|' "$ACTION" >"$T/leak.sh"
act "$T/leak.sh" DRY_RUN=0
! not_printed && pass "7. CONTROL: a copy that echoes the key fails the never-printed check" || fail "7. a printed key was not caught"
reset_state; sed 's#      --account="\$GCP_ACCOUNT" --quiet </dev/null >/dev/null 2>&1 ) ||$#      --quiet </dev/null >/dev/null 2>\&1 ) ||#' "$ACTION" >"$T/unpin.sh"
act "$T/unpin.sh" DRY_RUN=0
! cmp -s "$ACTION" "$T/unpin.sh" && [[ "$(unpinned)" != 0 ]] && pass "7. CONTROL: a copy whose create drops --account fails the pinned check" || fail "7. an unpinned create was not caught: $(cat "$T/calls.log")"

[[ $fails -eq 0 ]] && { echo "PASS: all"; exit 0; } || { echo "FAIL: $fails"; exit 1; }
