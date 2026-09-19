#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: prove do_gcp_001_create_project never issues `gcloud projects create`
#          (or a billing link) unless it has READ that the project is absent,
#          was told to mutate (DRY_RUN=0), and holds a live credential -- by
#          CALLING it against a stubbed gcloud and inspecting the recorded argv,
#          not by grepping the source.
#
#          Adapted from pas-psf-iac/src/bash/tests/gcp-001-dead-credential-no-create.tst.sh.
#          Kept: the dead-credential, exit-0-but-empty, unreadable-describe and
#          happy-path cases. Added for the spool: dry run is the default, every
#          gcloud call pins --account, the shared gcloud config is never
#          written, and the parent (org or folder) fails fast when missing.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC_FILE="$PROJ_ROOT/src/bash/run/gcp-001-create-project.func.sh"
LIB_FILE="$PROJ_ROOT/lib/bash/funcs/gcp-require-live-account.func.sh"
PIN_FILE="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh"
# an APP_PATH with no cnf: the account / org then come from the env or nowhere
NOCNF=$(mktemp -d); trap 'rm -rf "$NOCNF"' EXIT
FUNC_NAME="do_gcp_001_create_project"

fails=0

for f in "$FUNC_FILE" "$LIB_FILE" "$PIN_FILE"; do
  [[ -f "$f" ]] || { echo "FAIL: not found: $f"; exit 1; }
  bash -n "$f" || { echo "FAIL: bash -n $f"; exit 1; }
  echo "PASS: bash -n $(basename "$f")"
done

#   live_exists   token mints; describe succeeds                   -> skip create
#   live_absent   token mints; describe says "(or it may not exist)" -> create (DRY_RUN=0 only)
#   dead_cred     token endpoint refuses (reauth)                  -> abort BEFORE anything
#   silent_deny   token call exits 0 printing NOTHING              -> abort
#   opaque_fail   token mints; describe fails with a 503           -> abort, no create
# run_action <mode> <log> [VAR=value ...]  -- extra assignments override the defaults
run_action() {
  local mode="$1" log="$2"; shift 2

  env MODE="$mode" GCLOUD_LOG="$log" FUNC_FILE="$FUNC_FILE" LIB_FILE="$LIB_FILE" PIN_FILE="$PIN_FILE" \
      FUNC_NAME="$FUNC_NAME" APP_PATH="$APP_ROOT" \
      ENV=dev GCP_ACCOUNT=stub-admin@example.com GCP_ORG_ID=123456789012 \
      GCP_BILLING_ACCOUNT_ID=XXXXXX-XXXXXX-XXXXXX \
      "$@" \
  bash <<'INNER'
    # quit_on and do_require_var are the REAL shapes from run.sh / lib: a stub
    # that always exits, or never does, proves nothing about the gate.
    quit_on(){ rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Failed to $1"; exit $rv; fi; }
    do_require_var() { [[ -n "${2:-}" ]] || { echo "FATAL $1 empty"; exit 1; }; }
    do_log()          { echo "$*"; }
    do_resolve_oap()  { export ORG=csi APP=spl; }

    gcloud() {
      echo "$*" >> "$GCLOUD_LOG"
      case "$1 ${2:-}" in
        "auth print-access-token")
          case "$MODE" in
            dead_cred)
              echo "ERROR: Reauthentication failed. cannot prompt during non-interactive execution." >&2
              return 1 ;;
            silent_deny) return 0 ;;
            *) echo "ya29.a0AfB_stub_token_value_that_is_long_enough"; return 0 ;;
          esac ;;
        "projects describe")
          case "$MODE" in
            live_exists) echo "csi-spl-dev"; return 0 ;;
            dead_cred)
              echo "ERROR: Reauthentication failed. cannot prompt during non-interactive execution." >&2
              return 1 ;;
            live_absent)
              echo "ERROR: (gcloud.projects.describe) User [x@y] does not have permission to access projects instance [csi-spl-dev] (or it may not exist)." >&2
              return 1 ;;
            opaque_fail)
              echo "ERROR: (gcloud.projects.describe) HTTPError 503: The service is currently unavailable." >&2
              return 1 ;;
          esac ;;
        "billing projects")
          [[ "${3:-}" == describe && "$MODE" == live_exists ]] && { echo "True"; return 0; }
          [[ "${3:-}" == describe ]] && return 1
          return 0 ;;
        *) return 0 ;;
      esac
    }

    # shellcheck disable=SC1090
    source "$LIB_FILE"
    # shellcheck disable=SC1090
    source "$PIN_FILE"
    # shellcheck disable=SC1090
    source "$FUNC_FILE"
    "$FUNC_NAME" >/dev/null 2>&1
INNER
}

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# --- 1. dead credential: nothing is read or created, token check first -------
log=$(mktemp); run_action dead_cred "$log" DRY_RUN=0
grep -q 'projects create' "$log" && fail "dead credential reached 'projects create'" || pass "dead credential never reached 'projects create'"
grep -q 'projects describe' "$log" && fail "dead credential ran the check it cannot read" || pass "dead credential aborted before the idempotency check"
[[ "$(head -1 "$log")" == "auth print-access-token"* ]] && pass "the pre-flight is the first gcloud call" || fail "first gcloud call was: $(head -1 "$log")"
rm -f "$log"

# --- 2. exit 0 with empty output is not consent ------------------------------
log=$(mktemp); run_action silent_deny "$log" DRY_RUN=0
grep -qE 'projects (create|describe)' "$log" && fail "an exit-0-but-empty token call was accepted" || pass "exit 0 with empty output is read as failure"
rm -f "$log"

# --- 3. an unreadable answer is not 'absent' ---------------------------------
log=$(mktemp); run_action opaque_fail "$log" DRY_RUN=0
grep -q 'projects create' "$log" && fail "a 503 on describe was misread as absent" || pass "an unclassifiable describe failure aborts instead of creating"
rm -f "$log"

# --- 4. the no-op path --------------------------------------------------------
log=$(mktemp); run_action live_exists "$log" DRY_RUN=0
grep -q 'projects create' "$log" && fail "an existing project triggered a create" || pass "an existing project takes the skip branch"
grep -q 'billing projects link' "$log" && fail "a linked project was re-linked" || pass "an already-linked project is not re-linked"
rm -f "$log"

# --- 5. DRY RUN IS THE DEFAULT: absent project, no DRY_RUN given --------------
log=$(mktemp); run_action live_absent "$log"; rc=$?
[[ $rc -eq 0 ]] && pass "the default dry run exits 0" || fail "the default dry run exited $rc"
grep -q 'projects create' "$log" && fail "the default run created a project" || pass "the default run (dry) does not create"
grep -q 'billing projects link' "$log" && fail "the default run linked billing" || pass "the default run (dry) does not link billing"
rm -f "$log"

# --- 6. DRY_RUN=0 on an absent project does create + link, pinned -------------
log=$(mktemp); run_action live_absent "$log" DRY_RUN=0
grep -q 'projects create csi-spl-dev .*--organization=123456789012' "$log" && pass "DRY_RUN=0 creates csi-spl-dev under the org" || fail "DRY_RUN=0 did not create csi-spl-dev under the org"
grep -q 'billing projects link csi-spl-dev --billing-account=XXXXXX-XXXXXX-XXXXXX' "$log" && pass "DRY_RUN=0 links the billing account" || fail "DRY_RUN=0 did not link billing"
unpinned=$(grep -vc -- '--account=stub-admin@example.com' "$log")
[[ "$unpinned" -eq 0 ]] && pass "every gcloud call carries --account ($(wc -l <"$log") calls)" || fail "$unpinned gcloud call(s) without --account"
rm -f "$log"

# --- 7. a folder parent is honoured -------------------------------------------
log=$(mktemp); run_action live_absent "$log" DRY_RUN=0 GCP_ORG_ID= GCP_FOLDER_ID=987654321
grep -q 'projects create csi-spl-dev .*--folder=987654321' "$log" && pass "GCP_FOLDER_ID creates under the folder" || fail "GCP_FOLDER_ID was not used"
rm -f "$log"

# --- 8. the shared gcloud config is never written, in any mode ----------------
log=$(mktemp)
for m in dead_cred silent_deny opaque_fail live_exists live_absent; do run_action "$m" "$log" DRY_RUN=0; done
grep -qE '^config set|^auth login|^auth activate' "$log" && fail "the action wrote the shared gcloud config" || pass "no 'config set', 'auth login' or 'auth activate' in any mode"
rm -f "$log"

# --- 9. fail fast: no parent, both parents, bad env, bad DRY_RUN --------------
# APP_PATH has no cnf here: an empty GCP_ACCOUNT / GCP_ORG_ID is only a refusal
# when the yaml does not supply one (with the real cnf it resolves from
# env.gcp; gcloud-account-pinned.tst.sh covers that side)
for case in "GCP_ORG_ID=" "GCP_FOLDER_ID=1" "ENV=tst" "DRY_RUN=yes" "GCP_BILLING_ACCOUNT_ID=" "GCP_ACCOUNT="; do
  log=$(mktemp); : >"$log"
  run_action live_absent "$log" DRY_RUN=0 APP_PATH="$NOCNF" $case; rc=$?
  if [[ $rc -ne 0 && ! -s "$log" ]]; then pass "fails fast before any gcloud call: $case"
  else fail "did not fail fast (rc=$rc, $(wc -l <"$log") gcloud calls): $case"; fi
  rm -f "$log"
done

if [[ "$fails" -eq 0 ]]; then
  echo "PASS: all $(basename "$0") assertions"
  exit 0
fi
echo "FAIL: $fails assertion(s) in $(basename "$0")"
exit 1
