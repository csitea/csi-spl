#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: characterization test of do_gcp_002_delete_project_service_account
#          (refactor round 25 row 01, SPL-3680): pins what the destructive
#          action does TODAY, so a later round can split it under C2. It
#          records behaviour, it does not judge it (the interactive
#          `gcloud auth login` and `gcloud config set account` inside the
#          private config are pinned as they are).
#   1. SA missing (describe fails): rc 0, "does not exist" logged, no keys
#      list / keys delete / SA delete call, the local key file removed
#   2. SA present, two keys: auth preamble, then describe, keys list, key
#      delete x2, SA delete, in that order, each with --project=<proj> and
#      --account=<the re-pinned SA>; rc 0, local key file removed
#   3. one key delete fails: WARN names the key, the second key and the SA
#      delete still run, rc 0
#   4. the SA delete fails: non-zero, ERROR names the SA, local key KEPT
#   5. `gcloud auth login` fails: non-zero, no describe call
#   6. ORG / APP / ENV / GCP_ACCOUNT missing: non-zero, no gcloud call
#   7. every gcloud call ran in one private CLOUDSDK_CONFIG, gone afterwards;
#      ~/.config/gcloud never created
# gcloud is a stub first on PATH (checked). No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-002-delete-project-service-account.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
require_action "$ACTION"

PROJ=csi-spl-dev
SA_EMAIL="$PROJ@$PROJ.iam.gserviceaccount.com"
RESOLVED_SA=resolved-sa@example.com
ISO_SA=isolated-sa@example.com
OWNER=owner@example.com
KEY_FILE="$T/home/.gcp/.csi/key-$PROJ.json"
mkdir -p "$T/stub" "$T/tmp"

# stub gcloud: logs "<CLOUDSDK_CONFIG>|<argv>"; answers from env
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
case "$*" in
  "auth login"*) exit "${LOGIN_RC:-0}" ;;
  "iam service-accounts describe"*) exit "${DESCRIBE_RC:-0}" ;;
  "iam service-accounts keys list"*) printf '%s\n' ${KEY_IDS:-} ;;
  "iam service-accounts keys delete ${KEY_FAIL:-<none>} "*) exit 1 ;;
  "iam service-accounts delete"*) exit "${SA_DELETE_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"

# NOTHING MUTATES GCP: the stub must shadow any real gcloud
[[ "$(PATH="$T/stub:$PATH" command -v gcloud)" == "$T/stub/gcloud" ]] \
  && pass "gcloud resolves to the stub" || { fail "gcloud is not the stub"; exit 1; }

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  rm -rf "${T:?}/home"; mkdir -p "$T/home/.gcp/.csi"; echo '{}' >"$KEY_FILE"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u PROJ_ID -u KEY_IDS -u KEY_FAIL \
    HOME="$T/home" TMPDIR="$T/tmp" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    ACTION="$ACTION" RESOLVED_SA="$RESOLVED_SA" ISO_SA="$ISO_SA" \
    ORG=csi APP=spl ENV=dev GCP_ACCOUNT="$OWNER" "$@" bash -c '
    source "$ACTION"
    do_log() { echo "$*"; }
    quit_on() { rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Error: Failed to $1"; exit $rv; fi; }
    do_gcp_account() { echo "$RESOLVED_SA"; }
    do_gcp_log_identity() { :; }
    do_gcp_isolated_active_account() { echo "$ISO_SA"; }
    do_gcp_002_delete_project_service_account' >"$T/out" 2>&1
}
calls() { cut -d'|' -f2- "$T/calls.log"; }
iam() { calls | grep '^iam '; }
has() { calls | grep -- "$1" >/dev/null; }

# --- 1. the SA does not exist -------------------------------------------------
act DESCRIBE_RC=1; rc=$?
[[ $rc -eq 0 ]] && grep -q "Service account $SA_EMAIL does not exist" "$T/out" \
  && pass "1. SA missing -> rc 0, 'does not exist' logged" || fail "1. rc=$rc $(cat "$T/out")"
[[ "$(iam | wc -l)" -eq 1 ]] && ! has '^iam service-accounts keys' && ! has '^iam service-accounts delete' \
  && pass "1. only the describe: no keys list, no key delete, no SA delete" || fail "1. calls: $(iam)"
[[ ! -e "$KEY_FILE" ]] && pass "1. the stale local key file is removed" || fail "1. key file kept"

# --- 2. SA present, two keys ---------------------------------------------------
act KEY_IDS="k1 k2"; rc=$?
[[ $rc -eq 0 ]] && pass "2. rc 0" || fail "2. rc=$rc $(cat "$T/out")"
want="iam service-accounts describe $SA_EMAIL
iam service-accounts keys list
iam service-accounts keys delete k1
iam service-accounts keys delete k2
iam service-accounts delete $SA_EMAIL"
got=$(iam | awk '{ if ($3 == "keys") print $1, $2, $3, $4, ($4 == "delete" ? $5 : ""); else print $1, $2, $3, $4 }' | sed 's/ *$//')
[[ "$got" == "$want" ]] && pass "2. describe, keys list, key delete x2, SA delete, in that order" \
  || fail "2. order: $got"
[[ "$(iam | grep -c -- "--project=$PROJ")" -eq 5 && "$(iam | grep -c -- "--account=$ISO_SA")" -eq 5 ]] \
  && pass "2. all 5 iam calls carry --project=$PROJ and --account=<the re-pinned SA>" || fail "2. flags: $(iam)"
pre="auth revoke --all
auth application-default revoke
auth login --update-adc --quiet
config set account $OWNER
auth print-access-token --account=$ISO_SA
auth application-default print-access-token"
[[ "$(calls | grep -v '^iam ')" == "$pre" ]] \
  && pass "2. the auth preamble as it is today: revoke, login, config set account, token checks" \
  || fail "2. preamble: $(calls | grep -v '^iam ')"
[[ ! -e "$KEY_FILE" ]] && pass "2. the local key file is removed" || fail "2. key file kept"

# --- 7. private gcloud config (from case 2's run) ----------------------------
cfgs=$(cut -d'|' -f1 "$T/calls.log" | sort -u)
[[ "$(wc -l <<<"$cfgs")" -eq 1 && "$cfgs" == "$T/tmp/"* ]] \
  && pass "7. every gcloud call ran in one private CLOUDSDK_CONFIG" || fail "7. configs: '$cfgs'"
[[ ! -e "$cfgs" && ! -e "$T/home/.config/gcloud" ]] \
  && pass "7. the private config is gone afterwards; ~/.config/gcloud never created" || fail "7. left: '$cfgs'"

# --- 3. one key delete fails ---------------------------------------------------
act KEY_IDS="k1 k2" KEY_FAIL=k1; rc=$?
[[ $rc -eq 0 ]] && grep -q "WARN Failed to delete key k1" "$T/out" \
  && pass "3. a failed key delete -> WARN names k1, rc 0" || fail "3. rc=$rc $(cat "$T/out")"
has '^iam service-accounts keys delete k2 ' && has "^iam service-accounts delete $SA_EMAIL " \
  && pass "3. the second key and the SA delete still run" || fail "3. calls: $(iam)"

# --- 4. the SA delete fails ----------------------------------------------------
act KEY_IDS="k1" SA_DELETE_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q "ERROR Failed to delete service account $SA_EMAIL" "$T/out" \
  && pass "4. a failed SA delete -> non-zero, ERROR names the SA" || fail "4. rc=$rc $(cat "$T/out")"
[[ -e "$KEY_FILE" ]] && pass "4. the local key file is kept" || fail "4. key file removed"

# --- 5. gcloud auth login fails -----------------------------------------------
act LOGIN_RC=1; rc=$?
[[ $rc -ne 0 ]] && ! has '^iam ' && grep -q "ERROR gcloud auth login failed" "$T/out" \
  && pass "5. auth login fails -> non-zero, no describe call" || fail "5. rc=$rc $(cat "$T/calls.log")"

# --- 6. a missing ORG / APP / ENV / GCP_ACCOUNT -------------------------------
for var in ORG APP ENV GCP_ACCOUNT; do
  act "$var="; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q "$var is required" "$T/out" \
    && pass "6. $var empty -> non-zero, no gcloud call" \
    || fail "6. $var empty: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
