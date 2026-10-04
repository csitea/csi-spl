#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: three gcp-* actions build their SA key path as
#          "$HOME/.gcp/.$ORG/key-....json", not $(eval echo ~/.gcp/...) (refactor
#          round 2, row 14). eval was there only to expand ~, and it also ran
#          anything in ORG / APP / ENV / GCP_PROJECT as code.
#   1. Each action resolves $HOME/.gcp/.<org>/key-<org>-<app>-<env>.json:
#      gcp-project-delete hands it to do_gcp_account (stubbed: records it,
#      then refuses, so the action stops before any gcloud call); the two
#      sync actions pass it to `gcloud auth activate-service-account`.
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
ACTIONS=(gcp-project-delete gcp-sync-s3-to-local gcp-sync-src-s3-to-tgt-s3-silent)
for a in "${ACTIONS[@]}"; do require_action "$RUN/$a.func.sh"; done

for c in gcloud gsutil yq jq; do stub "$c" "echo \"$c|\$*\" >>\"\$STUB_LOG\""; done
mkdir -p "$T/home"

# drive <action> <ORG> - runs the action with every helper stubbed; the argv
# log is $T/calls.log, the key do_gcp_account was handed is $T/key.log
drive() {
  : >"$T/calls.log"; : >"$T/key.log"
  env -u GCP_SA_KEY_FILE -u GCP_PROJECT HOME="$T/home" PATH="$T/bin:$PATH" \
      STUB_LOG="$T/calls.log" ACTION="$RUN/$1.func.sh" FN="do_${1//-/_}" \
      ORG="$2" APP=spl ENV=dev SRC_ENV=dev TGT_ENV=prd FORCE=true \
      BASE_PATH="$T/none" APP_PATH="$T" TGT_DIR="$T/tgt" \
  bash -c '
    do_log() { :; }; do_require_var() { :; }; do_gcp_log_identity() { :; }
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
  if [[ "$1" == gcp-project-delete ]]; then head -1 "$T/key.log"
  else sed -n 's/^gcloud|auth activate-service-account --key-file=//p' "$T/calls.log" | sed -n 1p; fi
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
done
grep -qxF "gcloud|auth activate-service-account --key-file=$T/home/.gcp/.csi/key-csi-spl-prd.json" "$T/calls.log" \
  && pass "1. gcp-sync-src-s3-to-tgt-s3-silent resolves the TGT_ENV key \$HOME/.gcp/.csi/key-csi-spl-prd.json" \
  || fail "1. gcp-sync-src-s3-to-tgt-s3-silent: no activation of the prd key"

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
