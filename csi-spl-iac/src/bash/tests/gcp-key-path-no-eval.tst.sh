#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: five actions build their SA key path as
#          "$HOME/.gcp/.$ORG/key-....json", not $(eval echo ~/.gcp/...) (refactor
#          round 2, row 14; round 4, row 12 for tf-init and gcp-s3-download-all).
#          eval was there only to expand ~, and it also ran anything in
#          ORG / APP / ENV / GCP_PROJECT as code.
#   1. Each action resolves $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json:
#      gcp-project-delete hands it to do_gcp_account (stubbed: records it,
#      then refuses, so the action stops before any gcloud call); the two
#      sync actions pass it to `gcloud auth activate-service-account`;
#      gcp-s3-download-all logs it as the missing key and stops; tf-init
#      exports it as GOOGLE_APPLICATION_CREDENTIALS, read by the flock stub,
#      which then fails so the action stops before it touches any dir.
#   2. With ORG='x$(touch $T/pwned)' no action creates $T/pwned, and the key
#      path carries the ORG text literally.
#   3. CONTROL: that same ORG through the old `eval echo ~/...` form does
#      create $T/pwned, so the payload in 2 is live.
#   4. Static: none of the three actions calls `eval`.
# Every gcloud / gsutil / yq / jq is a stub on PATH that only records argv.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export T

fails=0
ACTIONS=(gcp-project-delete gcp-sync-s3-to-local gcp-sync-src-s3-to-tgt-s3-silent gcp-s3-download-all tf-init)
for a in "${ACTIONS[@]}"; do require_action "$RUN/$a.func.sh"; done

for c in gcloud gsutil yq jq; do stub "$c" "echo \"$c|\$*\" >>\"\$STUB_LOG\""; done
stub flock 'echo "flock|GAC=$GOOGLE_APPLICATION_CREDENTIALS" >>"$STUB_LOG"; exit 1'
mkdir -p "$T/home"

# drive <action> <ORG> - runs the action with every helper stubbed; the argv
# log is $T/calls.log, the key do_gcp_account was handed is $T/key.log,
# every do_log line is $T/log.log
drive() {
  : >"$T/calls.log"; : >"$T/key.log"; : >"$T/log.log"
  env -u GCP_SA_KEY_FILE -u GCP_PROJECT HOME="$T/home" PATH="$T/bin:$PATH" \
      STUB_LOG="$T/calls.log" ACTION="$RUN/$1.func.sh" FN="do_${1//-/_}" \
      ORG="$2" APP=spl ENV=dev STEP=000-step SRC_ENV=dev TGT_ENV=prd FORCE=true \
      BASE_PATH="$T/none" APP_PATH="$T" TGT_DIR="$T/tgt" TARGET_BASE="$T/var" \
  bash -c '
    do_log() { echo "$*" >>"$T/log.log"; }; do_require_var() { :; }; do_gcp_log_identity() { :; }
    do_export_json_section_vars_as_tf_vars() { :; }
    do_export_json_section_vars() { [[ "$2" == .env.gcp ]] && export GCP_PROJECT="$ORG-$APP-$ENV"; :; }
    quit_on() { rv=$?; [ $rv -ne 0 ] && { echo "FATAL $1"; exit $rv; }; }
    do_gcp_isolated_active_account() { echo sa@example.com; }
    do_gcp_account() {
      echo "${GCP_SA_KEY_FILE:-<unset>}" >>"$T/key.log"
      [[ "$FN" == do_gcp_project_delete ]] && return 1
      echo sa@example.com
    }
    source "$ACTION"; "$FN"
  ' >/dev/null 2>&1
}

# key_of <action> - the key path the action resolved
key_of() {
  case "$1" in
    gcp-project-delete)  head -1 "$T/key.log" ;;
    gcp-s3-download-all) sed -n 's/^FATAL service account key not found: //p' "$T/log.log" | sed -n 1p ;;
    tf-init)             sed -n 's/^flock|GAC=//p' "$T/calls.log" | sed -n 1p ;;
    *) sed -n 's/^gcloud|auth activate-service-account --key-file=//p' "$T/calls.log" | sed -n 1p ;;
  esac
}

# --- 1. the key path, under $HOME ----------------------------------------------
for a in "${ACTIONS[@]}"; do
  drive "$a" csi
  got=$(key_of "$a")
  [[ "$got" == "$T/home/.gcp/.csi/key-csi-spl-dev.json" ]] \
    && pass "1. $a resolves \$HOME/.gcp/.csi/key-csi-spl-dev.json" \
    || fail "1. $a resolved '$got'"
  if [[ "$a" == gcp-project-delete ]]; then
    [[ ! -s "$T/calls.log" ]] && pass "1. $a stopped at the refused identity, before any gcloud / gsutil call" \
      || fail "1. $a reached a stub: $(head -1 "$T/calls.log")"
  fi
  if [[ "$a" == gcp-sync-src-s3-to-tgt-s3-silent ]]; then
    grep -qxF "gcloud|auth activate-service-account --key-file=$T/home/.gcp/.csi/key-csi-spl-prd.json" "$T/calls.log" \
      && pass "1. $a resolves the TGT_ENV key \$HOME/.gcp/.csi/key-csi-spl-prd.json" \
      || fail "1. $a: no activation of the prd key"
  fi
done

# --- 2. a hostile ORG is data, not code ----------------------------------------
# shellcheck disable=SC2016  # the $(...) must reach the action unexpanded
EVIL='x$(touch $T/pwned)'
for a in "${ACTIONS[@]}"; do
  rm -f "$T/pwned"
  drive "$a" "$EVIL"
  [[ ! -e "$T/pwned" ]] && pass "2. $a did not run the code in ORG" \
    || fail "2. $a ran the code in ORG (created \$T/pwned)"
  got=$(key_of "$a")
  [[ "$got" == "$T/home/.gcp/.$EVIL/key-"* ]] && pass "2. $a keeps ORG literal in the key path" \
    || fail "2. $a key path '$got'"
done

# --- 3. CONTROL: the old form runs the same payload ------------------------------
rm -f "$T/pwned"
# shellcheck disable=SC2088  # the ~ is quoted on purpose: eval expands it, as the old code did
(ORG="$EVIL"; HOME="$T/home"; eval echo "~/.gcp/.${ORG}/key.json" >/dev/null)
[[ -e "$T/pwned" ]] && pass "3. CONTROL: the old \$(eval echo ~/...) form runs the payload (\$T/pwned created)" \
  || fail "3. CONTROL: the payload did not fire through eval, so 2 proves nothing"

# --- 4. static ------------------------------------------------------------------
for a in "${ACTIONS[@]}"; do
  if grep -qE '^[^#]*\beval\b' "$RUN/$a.func.sh"; then fail "4. $a still calls eval"
  else pass "4. $a has no eval"; fi
done

[[ $fails -eq 0 ]] && pass "all $(basename "$0") assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
