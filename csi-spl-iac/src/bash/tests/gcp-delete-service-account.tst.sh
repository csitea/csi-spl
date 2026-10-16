#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_delete_service_account is a destructive action; it deletes
#          ONE service account, as the env's project SA, in a private gcloud
#          config, and nothing else (test round 1 row 08, SPL-2256).
#   1. SA listed: exactly one `iam service-accounts delete <SA_HEAD>@<proj>`
#      with --project, --quiet and --account=<the env SA>; the list too
#   2. every gcloud call (incl. `auth revoke --all`) ran in a private
#      CLOUDSDK_CONFIG, removed afterwards; ~/.config/gcloud never written
#   3. SA not listed -> rc 0, says so, no delete call
#   4. the delete fails -> non-zero, the failure is named
#   5. ENV empty, no ACCOUNT -> refused, no `gcloud iam` call at all
#   6. ENV empty, ACCOUNT set -> refused (no key to activate), no `gcloud iam`
#   7. CONTROL: no key -> refused, no `gcloud iam` call at all
# The action has NO DRY_RUN guard today: a run with a listed SA deletes it.
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-delete-service-account.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
TARGET=sa-ci-csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/tmp"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# stub gcloud: logs "<CLOUDSDK_CONFIG>|<argv>"; a key that is not a file
# fails the activate, as real gcloud does; the list prints $SA_LIST
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*)
    k=$(arg --key-file "$@"); [[ -f "$k" ]] || exit 1
    jq -r .client_email "$k" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth revoke"*) rm -f "$CLOUDSDK_CONFIG/active" ;;
  "iam service-accounts list"*) printf '%s\n' ${SA_LIST:-} ;;
  "iam service-accounts delete"*) exit "${DELETE_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u PROJ_ID -u GCP_SA_KEY_FILE \
    HOME="$T/home" TMPDIR="$T/tmp" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" ORG=csi APP=spl ENV=dev SA_HEAD=sa-ci-csi-spl-dev \
    SA_LIST="$DEV_SA $TARGET" "$@" bash -c '
    do_log() { echo "$*"; }
    quit_on() { rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Error: Failed to $1"; exit $rv; fi; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/gcp-delete-service-account.func.sh; do source "$f"; done
    do_gcp_delete_service_account' >"$T/out" 2>&1
}
iam_calls() { grep -c '|iam ' "$T/calls.log"; }
deletes() { grep '|iam service-accounts delete' "$T/calls.log"; }

# --- 1. the SA is listed: one delete, flags pinned ----------------------------
act; rc=$?
[[ $rc -eq 0 && "$(deletes | wc -l)" -eq 1 ]] && deletes | grep "|iam service-accounts delete $TARGET " >/dev/null \
  && pass "1. one delete, of SA_HEAD@<org>-<app>-<env> only" || fail "1. delete: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
d=$(deletes)
[[ "$d" == *" --project=csi-spl-dev"* && "$d" == *" --quiet"* && "$d" == *" --account=$DEV_SA"* ]] \
  && pass "1. the delete carries --project, --quiet and --account=<env SA>" || fail "1. flags: '$d'"
[[ "$(iam_calls)" -ge 2 && "$(iam_calls)" == "$(grep '|iam ' "$T/calls.log" | grep -c -- "--account=$DEV_SA")" ]] \
  && pass "1. every gcloud iam call (list + delete) as the env project SA" || fail "1. identity: $(cat "$T/calls.log")"

# --- 2. private gcloud config ------------------------------------------------
cfgs=$(cut -d'|' -f1 "$T/calls.log" | sort -u)
[[ -n "$cfgs" && "$(wc -l <<<"$cfgs")" -eq 1 && "$cfgs" != "<unset>" && "$cfgs" != "$T/home/.config/gcloud" ]] \
  && grep -q '|auth revoke --all' "$T/calls.log" \
  && pass "2. every call, auth revoke --all included, in one private CLOUDSDK_CONFIG" || fail "2. configs: '$cfgs'"
[[ ! -e "$cfgs" && ! -e "$T/home/.config/gcloud" ]] \
  && pass "2. the private config is removed afterwards; ~/.config/gcloud untouched" || fail "2. left: '$cfgs'"

# --- 3. the SA is not listed -------------------------------------------------
act SA_LIST="$DEV_SA"; rc=$?
[[ $rc -eq 0 && -z "$(deletes)" ]] && grep -q "Service account $TARGET does not exist in csi-spl-dev" "$T/out" \
  && pass "3. SA not listed -> rc 0, says so, no delete call" || fail "3. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 4. the delete fails -----------------------------------------------------
act DELETE_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL Error: Failed to delete service account $TARGET" "$T/out" \
  && pass "4. a failed delete -> non-zero, named" || fail "4. rc=$rc $(cat "$T/out")"

# --- 5. ENV empty, no ACCOUNT ------------------------------------------------
act ENV=; rc=$?
[[ $rc -ne 0 && "$(iam_calls)" -eq 0 ]] && grep -q 'FATAL no gcloud account' "$T/out" \
  && pass "5. ENV empty -> refused, no gcloud iam call" || fail "5. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 6. ENV empty, ACCOUNT set -----------------------------------------------
act ENV= ACCOUNT="$DEV_SA"; rc=$?
[[ $rc -ne 0 && "$(iam_calls)" -eq 0 ]] && grep -q 'FATAL Error: Failed to re-pin --account' "$T/out" \
  && pass "6. ENV empty + ACCOUNT -> refused at the key activate, no gcloud iam call" || fail "6. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 7. CONTROL: no key ------------------------------------------------------
mv "$T/home/.gcp/.csi/key-csi-spl-dev.json" "$T/key.json"
act; rc=$?
[[ $rc -ne 0 && "$(iam_calls)" -eq 0 ]] && grep -q 'FATAL no gcloud account' "$T/out" && pass "7. CONTROL: no key -> refused, no gcloud iam call" || fail "7. rc=$rc $(cat "$T/calls.log")"
mv "$T/key.json" "$T/home/.gcp/.csi/key-csi-spl-dev.json"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
