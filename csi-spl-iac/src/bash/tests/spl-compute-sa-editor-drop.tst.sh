#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_compute_sa_editor_drop (security round 1 row 6, SPL-1967)
#          drops roles/editor from the default compute SA only when told, only
#          after a measurement finds no use, and touches no other binding.
#   1. DRY_RUN unset, nothing uses it: every count 0, the command printed, NO
#      remove call; every call as the dev project SA on csi-spl-dev
#   2. DRY_RUN=0: exactly one remove-iam-policy-binding, of that member and
#      roles/editor only, then the policy is re-read; an undo line
#   3. CONTROL: a Cloud Run service with an EMPTY service account (= runs as
#      the default compute SA) -> refused, no remove (fails when the use
#      check is removed)
#   4. audit rows where it is the caller -> refused
#   5. the audit control finds no row at all (unreadable log) -> refused
#   6. a disabled Cloud Build API is 0 and never called; an enabled one is
#      listed
#   7. the SA holds no editor -> nothing to drop, no measurement
#   8. DRY_RUN=2 -> refused before any gcloud call
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-compute-sa-editor-drop.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
CSA=111-compute@developer.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

cat >"$T/stub/gcloud" <<'EOF_G'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
CSA=111-compute@developer.gserviceaccount.com
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "projects describe"*) echo 111 ;;
  "projects get-iam-policy"*)
    if [[ -f "$STUB_DIR/removed" || -n "${STUB_NO_EDITOR:-}" ]]; then m='"serviceAccount:x@y"'; else m="\"serviceAccount:$CSA\",\"user:o@example.com\""; fi
    echo "{\"bindings\":[{\"role\":\"roles/editor\",\"members\":[$m]},{\"role\":\"roles/viewer\",\"members\":[\"serviceAccount:$CSA\"]}]}" ;;
  "projects remove-iam-policy-binding"*) touch "$STUB_DIR/removed" ;;
  "services list"*) echo run.googleapis.com; [[ -n "${STUB_BUILD_ON:-}" ]] && echo cloudbuild.googleapis.com; echo logging.googleapis.com ;;
  "run services list"*) printf '[{"metadata":{"name":"hub"},"spec":{"template":{"spec":{"serviceAccountName":"%s"}}}}]\n' "${STUB_RUN_SA-hub@p.iam.gserviceaccount.com}" ;;
  "run jobs list"*|"compute instances list"*|"iam service-accounts keys list"*) echo '[]' ;;
  "builds list"*) echo '[{"id":"b1","serviceAccount":"projects/p/serviceAccounts/other@p"}]' ;;
  "logging read protoPayload"*) [[ -n "${STUB_AUDIT:-}" ]] && echo '[{"timestamp":"2026-10-01T00:00:00Z"}]' || echo '[]' ;;
  "logging read logName"*) [[ -n "${STUB_NO_LOG:-}" ]] && echo '[]' || echo '[{"timestamp":"2026-10-14T00:00:00Z"}]' ;;
esac
exit 0
EOF_G
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"; rm -f "$T/removed"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" STUB_DIR="$T" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/spl-compute-sa-editor-drop.func.sh; do source "$f"; done
    do_spl_compute_sa_editor_drop' >"$T/out" 2>&1
}
removes() { grep -c '|projects remove-iam-policy-binding' "$T/calls.log"; }

# --- 1. dry run ----------------------------------------------------------------------
act; rc=$?
[[ $rc -eq 0 && $(removes) -eq 0 ]] && grep -q "DRY_RUN would run: gcloud projects remove-iam-policy-binding csi-spl-dev --member=serviceAccount:$CSA --role=roles/editor --condition=None" "$T/out" \
  && pass "1. DRY_RUN unset: the command printed, no remove" || fail "1. rc=$rc $(cat "$T/out")"
[[ $(grep -c ": 0$" "$T/out") -eq 7 ]] && grep -q 'nothing uses it' "$T/out" && pass "1. seven sources measured, each 0" || fail "1. counts: $(cat "$T/out")"
n=$(grep -cvE '\|auth ' "$T/calls.log"); m=$(grep -vE '\|auth ' "$T/calls.log" | grep -- "--account=$DEV_SA" | grep -c -- '--project=csi-spl-dev')
[[ $n -ge 9 && $n -eq $m ]] && pass "1. all $n calls as the dev project SA on csi-spl-dev" || fail "1. identity $n/$m $(cat "$T/calls.log")"

# --- 2. real run -----------------------------------------------------------------------
act DRY_RUN=0; rc=$?
line=$(grep '|projects remove-iam-policy-binding' "$T/calls.log" | cut -d'|' -f2-)
[[ $rc -eq 0 && $(removes) -eq 1 && "$line" == "projects remove-iam-policy-binding csi-spl-dev --member=serviceAccount:$CSA --role=roles/editor --condition=None --account=$DEV_SA --quiet" ]] \
  && pass "2. DRY_RUN=0: exactly one remove, that member and roles/editor only" || fail "2. rc=$rc '$line' $(cat "$T/out")"
[[ $(grep -c '|projects get-iam-policy' "$T/calls.log") -eq 2 ]] && grep -q "OK dropped roles/editor from $CSA in csi-spl-dev; undo: gcloud projects add-iam-policy-binding" "$T/out" \
  && pass "2. the policy is re-read; an undo line" || fail "2. out: $(cat "$T/out")"

# --- 3. CONTROL: empty Cloud Run SA ---------------------------------------------------------
act DRY_RUN=0 STUB_RUN_SA=; rc=$?
[[ $rc -ne 0 && $(removes) -eq 0 ]] && grep -q 'Cloud Run services: 1 (hub)' "$T/out" && grep -q 'is in use (1): refusing' "$T/out" \
  && pass "3. CONTROL: a service with no SA runs as it -> refused, no remove" || fail "3. rc=$rc $(cat "$T/out")"

# --- 4. audit rows --------------------------------------------------------------------------
act DRY_RUN=0 STUB_AUDIT=1; rc=$?
[[ $rc -ne 0 && $(removes) -eq 0 ]] && grep -q 'audit rows as caller, 30 d: 1' "$T/out" && pass "4. audit rows as caller -> refused" || fail "4. rc=$rc $(cat "$T/out")"

# --- 5. unreadable log --------------------------------------------------------------------
act DRY_RUN=0 STUB_NO_LOG=1; rc=$?
[[ $rc -ne 0 && $(removes) -eq 0 ]] && grep -q 'unreadable, so 0 proves nothing' "$T/out" && pass "5. no audit row at all -> refused" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6. API gates ---------------------------------------------------------------------------
act
! grep -qE '\|(builds|functions) ' "$T/calls.log" && grep -q 'API disabled, so 0: cloudfunctions.googleapis.com, cloudbuild.googleapis.com' "$T/out" \
  && pass "6. disabled Functions and Build APIs: 0, never called" || fail "6. off: $(cat "$T/calls.log")"
act STUB_BUILD_ON=1; rc=$?
[[ $rc -eq 0 ]] && grep -q '|builds list' "$T/calls.log" && pass "6. an enabled Build API is listed (other SA: 0)" || fail "6. on: rc=$rc $(cat "$T/out")"

# --- 7. no editor ---------------------------------------------------------------------------
act DRY_RUN=0 STUB_NO_EDITOR=1; rc=$?
[[ $rc -eq 0 && $(removes) -eq 0 ]] && grep -q 'nothing to drop' "$T/out" && ! grep -q '|run services' "$T/calls.log" \
  && pass "7. no editor binding -> nothing to drop, no measurement" || fail "7. rc=$rc $(cat "$T/out")"

# --- 8. bad DRY_RUN ---------------------------------------------------------------------------
act DRY_RUN=2; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "8. DRY_RUN=2 -> refused, no gcloud call" || fail "8. rc=$rc"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
