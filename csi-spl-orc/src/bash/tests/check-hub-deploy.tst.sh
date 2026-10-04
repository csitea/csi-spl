#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_hub_deploy (spec 008 FR-P09) reads the live hub service
#          and compares it with cnf env.hub.image.ref -- and only reads.
#   1. current   (image == cnf ref, Ready, latest revision ready) -> rc 0
#   2. lagging   (another image)                                  -> rc 3
#      minted versions: a tag at/above the cnf floor is current; with
#      SPL_HUB_IMAGE_TAG (the deploy job) only exactly that tag is
#   3. unhealthy (Ready False / latest revision not the ready one) -> rc 4,
#      Ready read by condition TYPE, not by position
#   4. describe fails (no service / no access)                     -> rc 1
#   5. no GCP_ACCOUNT and no per-env SA key -> refused, never the owner account
#   6. every gcloud call carries --account, and none mutates
#      (no update / deploy / create / delete / set-iam / add-iam)
#      CONTROL: the stub records a call when one is made.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# nosa_home: a HOME with no ~/.gcp: no per-env SA key, while the REAL cnf
# still carries env.gcp.gcp_account_owner_email -- the CONTROL that a missing
# key is refused and the owner account is NEVER the fallback (owner rule
# 2026-09-19: the per-env service accounts only)
mkdir -p "$T/nosa_home"

# gcloud stub: records every call; mints a fake token; `run services describe`
# prints $FIXTURE, or fails when FIXTURE is empty.
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
    do_check_hub_deploy'
}

ref=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/ref" bash -c '
  do_log() { :; }; for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf && echo "$SPL_IMAGE_REF"')
[[ -n "$ref" ]] || { fail "cannot resolve the dev cnf image ref"; exit 1; }

fixture() { # <file> <image> <ready> <created> <latest>
  cat >"$1" <<EOF
{"spec":{"template":{"spec":{"containers":[{"image":"$2"}]}}},
 "status":{"conditions":[{"type":"ConfigurationsReady","status":"True"},{"type":"Ready","status":"$3"}],
           "latestCreatedRevisionName":"$4","latestReadyRevisionName":"$5"}}
EOF
}

check() { # <label> <want rc> <want verdict word or ""> [env...]
  local label="$1" want="$2" word="$3"; shift 3
  out=$(in_orc GCP_ACCOUNT=op@example.com "$@" 2>"$T/err"); rc=$?
  if [[ $rc -eq $want && ( -z "$word" || "$out" == "dev $word "* ) ]]; then pass "$label (rc $rc)"
  else fail "$label: rc=$rc want $want, out='$out' err='$(tail -1 "$T/err")'"; fi
}

fixture "$T/current.json" "$ref" True r-2 r-2
fixture "$T/lagging.json" "${ref%:*}:0.0.0-old" True r-1 r-1
fixture "$T/notready.json" "$ref" False r-3 r-2
fixture "$T/rollout.json" "$ref" True r-3 r-2

: >"$T/calls.log"
check "current: cnf image, Ready, latest revision ready" 0 current FIXTURE="$T/current.json"
check "lagging: service runs another image"               3 lagging FIXTURE="$T/lagging.json"
check "unhealthy: Ready=False (read by type, not index)"  4 unhealthy FIXTURE="$T/notready.json"
check "unhealthy: latest created revision is not ready"   4 unhealthy FIXTURE="$T/rollout.json"
check "describe fails -> cannot tell"                     1 "" FIXTURE=

# The release version is minted per deploy; cnf hub.image.tag is the floor.
floor="${ref##*:}"
IFS=. read -r fa fb fc <<<"$floor"
ahead="$fa.$fb.$(( fc < 9 ? fc + 1 : fc ))"; [[ "$ahead" != "$floor" ]] || ahead="$fa.$(( fb < 9 ? fb + 1 : fb )).0"
behind="0.0.0"
fixture "$T/ahead.json" "${ref%:*}:$ahead" True r-4 r-4
fixture "$T/behind.json" "${ref%:*}:$behind" True r-4 r-4
fixture "$T/otherrepo.json" "example.com/other/spool-hub:$ahead" True r-4 r-4
check "current: a minted tag ABOVE the floor ($ahead > $floor), no SPL_HUB_IMAGE_TAG" 0 current FIXTURE="$T/ahead.json"
check "lagging: a tag BELOW the floor ($behind < $floor)"                            3 lagging FIXTURE="$T/behind.json"
check "lagging: a later tag in ANOTHER repository"                                   3 lagging FIXTURE="$T/otherrepo.json"
check "current: SPL_HUB_IMAGE_TAG=$ahead and the service runs exactly it"            0 current FIXTURE="$T/ahead.json" SPL_HUB_IMAGE_TAG="$ahead"
check "lagging: SPL_HUB_IMAGE_TAG=$ahead but the service still runs the floor"       3 lagging FIXTURE="$T/current.json" SPL_HUB_IMAGE_TAG="$ahead"

out=$(in_orc GCP_ACCOUNT= HOME="$T/nosa_home" FIXTURE="$T/current.json" 2>&1); rc=$?
owner=$(yq -r '.env.gcp.gcp_account_owner_email // ""' "$APP_ROOT"/*-cnf/*/all.env.yaml)
[[ $rc -ne 0 && -n "$owner" ]] && grep -q 'no project SA key' <<<"$out" && ! grep -qF "$owner" <<<"$out" \
  && pass "no GCP_ACCOUNT and no SA key is refused; the cnf owner account is never used" || fail "no account: rc=$rc $out"

n=$(grep -c '^gcloud ' "$T/calls.log")
[[ $n -ge 10 ]] && pass "control: the stub recorded $n gcloud calls" || fail "control: stub recorded only $n calls"
if grep -vq -- '--account=op@example.com' "$T/calls.log"; then fail "a gcloud call without --account: $(grep -v -- '--account=' "$T/calls.log" | sed -n 1p)"
else pass "every gcloud call carries --account"; fi
if grep -Eq ' (update|deploy|create|delete|set-iam-policy|add-iam-policy-binding|replace)( |$)' "$T/calls.log"; then
  fail "a mutating gcloud call: $(grep -E ' (update|deploy|create|delete|set-iam-policy|add-iam-policy-binding|replace)( |$)' "$T/calls.log" | sed -n 1p)"
else pass "no mutating gcloud call (describe + token mint only)"; fi

[[ $fails -eq 0 ]] && echo "PASS: all check-hub-deploy assertions" || { echo "FAILED: $fails"; exit 1; }
