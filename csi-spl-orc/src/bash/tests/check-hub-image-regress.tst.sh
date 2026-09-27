#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_hub_image_regress is the 030 pre-apply precondition.
#   1. cnf image == live image                       -> rc 0 current
#   2. cnf tag NEWER than live (a roll)              -> rc 0 forward
#   3. cnf tag OLDER than live, 030 ignores the image -> rc 0 ahead (the
#      release version is minted per deploy, so live leads the cnf floor)
#   3b. cnf tag OLDER than live, 030 still sets it   -> rc 3 regress
#      CONTROL: this is the 2026-09-21 foot-gun -- an artificially stale cnf
#      tag makes the precondition red, and `make do-provision` then refuses.
#   4. a different repository (no version order)     -> rc 3 diverged
#   5. ALLOW_IMAGE_REGRESS=1 permits the rollback    -> rc 0, verdict still printed
#   6. describe fails                                -> rc 1 cannot tell
#   7. read-only: every gcloud call carries --account and none mutates
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
cat >"$T/stub/gcloud" <<'EOF'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  "auth print-access-token"*) echo fake-token; exit 0 ;;
  "run services describe"*) [ -n "$FIXTURE" ] && cat "$FIXTURE" && exit 0
                            echo "ERROR: (gcloud.run.services.describe) NOT_FOUND" >&2; exit 1 ;;
esac
exit 1
EOF
chmod +x "$T/stub/gcloud"

export ENV=dev
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_check_hub_image_regress'
}

ref=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/ref" bash -c '
  do_log() { :; }; for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf && echo "$SPL_IMAGE_REF"')
[[ -n "$ref" ]] || { fail "cannot resolve the dev cnf image ref"; exit 1; }
repo="${ref%:*}"; tag="${ref##*:}"

fixture() { printf '{"spec":{"template":{"spec":{"containers":[{"image":"%s"}]}}}}\n' "$2" >"$1"; }

check() { # <label> <want rc> <want verdict word> [env...]
  local label="$1" want="$2" word="$3"; shift 3
  out=$(in_orc GCP_ACCOUNT=op@example.com "$@" 2>"$T/err"); rc=$?
  if [[ $rc -eq $want && ( -z "$word" || "$out" == "dev $word "* ) ]]; then pass "$label (rc $rc)"
  else fail "$label: rc=$rc want $want, out='$out' err='$(tail -1 "$T/err")'"; fi
}

# The live tags the fixtures pretend to be serving. 9999.0.0 is newer than any
# real cnf tag, so "live newer than cnf" is the stale-tree case regardless of
# what dev.env.yaml names today.
fixture "$T/same.json"     "$ref"
fixture "$T/older.json"    "$repo:0.0.1"
fixture "$T/newer.json"    "$repo:9999.0.0"
fixture "$T/otherepo.json" "europe-north1-docker.pkg.dev/other/other/spool-hub:$tag"

: >"$T/calls.log"
check "cnf image == live image"                       0 current  FIXTURE="$T/same.json"
check "cnf NEWER than live: a roll, allowed"          0 forward  FIXTURE="$T/older.json"
# A tree whose 030 ignores the image: the minted live tag is ahead by design.
check "minted tag ahead of the floor, 030 ignores it"  0 ahead    FIXTURE="$T/newer.json"
# CONTROL: the same live tag against a 030 WITHOUT the ignore line (a tree
# from before minting) is still the 2026-09-21 foot-gun and still refused.
tf030="$APP_ROOT/csi-spl-iac/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf"
grep -v 'template\[0\]\.containers\[0\]\.image' "$tf030" >"$T/stale-030.tf"
check "CONTROL stale tree: cnf OLDER than live"       3 regress  FIXTURE="$T/newer.json" SPL_TF030_FILE="$T/stale-030.tf"
check "different repository does not version-compare" 3 diverged FIXTURE="$T/otherepo.json"
check "ALLOW_IMAGE_REGRESS=1 permits the rollback"    0 regress  FIXTURE="$T/newer.json" ALLOW_IMAGE_REGRESS=1 SPL_TF030_FILE="$T/stale-030.tf"
check "describe fails -> cannot tell"                 1 ""       FIXTURE=

# CONTROL on the wiring: the do-provision target must call this action for 030
# and must NOT call it for any other step.
mk="$PROJ_ROOT/src/make/tf-tasks.func.mk"
if grep -q 'do_check_hub_image_regress' "$mk" && grep -q '030-cloud-run-hub' "$mk"; then
  pass "make do-provision gates step 030 on the precondition"
else fail "make do-provision does not call do_check_hub_image_regress for 030"; fi
if awk '/^do-provision:/,/^$/' "$mk" | grep -q 'do_check_hub_image_regress'; then
  pass "the gate sits in the do-provision recipe (before the apply)"
else fail "the gate is not inside the do-provision recipe"; fi

n=$(grep -c '^gcloud ' "$T/calls.log")
[[ $n -ge 6 ]] && pass "control: the stub recorded $n gcloud calls" || fail "control: stub recorded only $n calls"
if grep -vq -- '--account=op@example.com' "$T/calls.log"; then fail "a gcloud call without --account"
else pass "every gcloud call carries --account"; fi
if grep -Eq ' (update|deploy|create|delete|set-iam-policy|add-iam-policy-binding|replace)( |$)' "$T/calls.log"; then
  fail "a mutating gcloud call"
else pass "no mutating gcloud call (describe + token mint only)"; fi

[[ $fails -eq 0 ]] && echo "PASS: all check-hub-image-regress assertions" || { echo "FAILED: $fails"; exit 1; }
