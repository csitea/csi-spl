#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_canary_hub_deploy (SPL-2249, Cloud Run radar step 3) rolls the
#          hub through a tagged 0 % revision and a traffic share, then
#          promotes it to latest 100 % or pins the old revision back.
#   1. pass: update --image --no-traffic --tag, --to-tags canary=<pct>, then
#      --to-latest --remove-tags; never --to-revisions; rc 0
#   2. 5xx gate: the canary's 5xx over the limit -> old revision pinned, rc 1
#   3. WS gate: no WS upgrade reached the canary while its share predicts
#      >= 5 (the 2026-10-16 hello deadlock signature) -> pinned, rc 1
#   4. a failed 0 % probe -> pinned before any traffic moves, rc 1
#   5. /version commit != EXPECT_COMMIT -> pinned before any traffic, rc 1
#   6. Monitoring unreadable -> fails closed (pinned), rc 1
#   7. DRY_RUN=1 (the default): describe only, every mutation printed
#   8. a split left by a killed run: pinned first; a rolled-back service is
#      retried, not "nothing to roll"; the same image + latest 100 %: no-op
#   9. CANARY_CMD=rollback pins the largest share and drops the tag
#  10. every gcloud call carries --account (and --project/--region on run)
#  11. the gate on 2026-10-16's measured prd numbers: the 5xx limit alone
#      PASSES the stuck window (7 of 1767), the WS rule FAILS it
#  12. cnf knobs are validated (percent 1..50, a Cloud Run tag)
#  13. workflow 20 runs it when cnf hub.cloud_run.canary.enabled is true
# gcloud, curl and sleep are stubs. The gcloud stub keeps the service's
# traffic state in $ST (before|tagged|split|promoted|pinned); the curl stub
# answers health from $HEALTH (one code per call, the last repeats),
# /version from $COMMIT and Monitoring from $MON_<revision> ("1xx 2xx 3xx 4xx
# 5xx", or "error"). CONTROL: every call is logged, so "no mutation" is
# counted, not assumed.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
WF="$APP_ROOT/.github/workflows/20_hub-build-deploy.yml"
IMG_OLD="example.com/hub/spool-hub:1.0.0"
IMG_NEW="example.com/hub/spool-hub:1.0.1"

mkdir -p "$T/stub"
cat >"$T/stub/gcloud" <<'EOF'
#!/bin/bash
echo "gcloud $*" >>"$STUB_LOG"
st="$(cat "$ST")"
case "$*" in
  "auth print-access-token"*) echo tok; exit 0 ;;
  "run services describe"*) ;;
  "run services update-traffic"*"--to-tags="*) echo split >"$ST"; exit 0 ;;
  "run services update-traffic"*"--to-latest"*) echo promoted >"$ST"; exit 0 ;;
  "run services update-traffic"*"--to-revisions="*) echo pinned >"$ST"; exit 0 ;;
  "run services update "*"--no-traffic"*) echo tagged >"$ST"; exit 0 ;;
  *) exit 1 ;;
esac
img="$IMG_OLD"; created=r-1
case "$st" in
  before)   tr='[{"latestRevision":true,"percent":100,"revisionName":"r-1"}]' ;;
  tagged)   img="$IMG_NEW"; created=r-2; tr='[{"percent":100,"revisionName":"r-1"},{"revisionName":"r-2","tag":"canary","url":"https://canary---hub.example.com"}]' ;;
  split)    img="$IMG_NEW"; created=r-2; tr='[{"percent":90,"revisionName":"r-1"},{"percent":10,"revisionName":"r-2","tag":"canary","url":"https://canary---hub.example.com"}]' ;;
  promoted) img="$IMG_NEW"; created=r-2; tr='[{"latestRevision":true,"percent":100,"revisionName":"r-2"}]' ;;
  pinned)   img="$IMG_NEW"; created=r-2; tr='[{"percent":100,"revisionName":"r-1"}]' ;;
esac
[ "${SAME:-0}" = 1 ] && img="$IMG_NEW"
printf '{"spec":{"template":{"spec":{"containers":[{"image":"%s"}]}}},"status":{"url":"https://hub.example.com","latestCreatedRevisionName":"%s","latestReadyRevisionName":"%s","traffic":%s}}\n' "$img" "$created" "$created" "$tr"
EOF
cat >"$T/stub/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
case "$*" in
  *"/v1/health"*)
    code=$(sed -n 1p "$HEALTH"); [ "$(wc -l <"$HEALTH")" -gt 1 ] && sed -i 1d "$HEALTH"
    printf %s "$code" ;;
  *"/version"*) printf '{"commit":"%s"}' "${COMMIT:-}" ;;
  *"monitoring.googleapis.com"*)
    rev=$(sed -nE 's/.*revision_name="([a-z0-9-]+)".*/\1/p' <<<"$*"); v="MON_${rev//-/_}"; v="${!v:-0 0 0 0 0}"
    [ "$v" = error ] && { echo '{"error":{"message":"denied"}}'; exit 0; }
    read -r a b c d e <<<"$v"
    printf '{"timeSeries":['
    printf '{"metric":{"labels":{"response_code_class":"1xx"}},"points":[{"value":{"int64Value":"%s"}}]},' "$a"
    printf '{"metric":{"labels":{"response_code_class":"2xx"}},"points":[{"value":{"int64Value":"%s"}}]},' "$b"
    printf '{"metric":{"labels":{"response_code_class":"3xx"}},"points":[{"value":{"int64Value":"%s"}}]},' "$c"
    printf '{"metric":{"labels":{"response_code_class":"4xx"}},"points":[{"value":{"int64Value":"%s"}}]},' "$d"
    printf '{"metric":{"labels":{"response_code_class":"5xx"}},"points":[{"value":{"int64Value":"%s"}}]}]}' "$e" ;;
esac
EOF
printf '#!/bin/sh\n:\n' >"$T/stub/sleep"
chmod +x "$T/stub/"*

# canary <state> <health codes> [VAR=value...] -> rc; out in $T/out, calls in $T/calls.log
canary() {
  local st="$1" health="$2"; shift 2
  : >"$T/calls.log"; echo "$st" >"$T/st"; printf '%s\n' $health >"$T/health"
  env -u DRY_RUN -u CANARY_CMD -u EXPECT_COMMIT PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" \
    STUB_LOG="$T/calls.log" PATH="$T/stub:$PATH" ENV=dev ST="$T/st" HEALTH="$T/health" GCP_ACCOUNT=deploy@example.com \
    IMG_OLD="$IMG_OLD" IMG_NEW="$IMG_NEW" IMAGE_REF="$IMG_NEW" MON_r_1="900 600 10 5 0" MON_r_2="100 66 1 0 0" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_canary_hub_deploy' >"$T/out" 2>&1
}
mut() { grep -E '^gcloud run services (update|update-traffic) ' "$T/calls.log"; }
nmut() { mut | grep -c .; }
has() { grep -qE -e "$1" "$T/calls.log"; }

# --- 1. pass -------------------------------------------------------------------
canary before 200 DRY_RUN=0 EXPECT_COMMIT=abc COMMIT=abc; rc=$?
[[ $rc -eq 0 && "$(cat "$T/st")" == promoted ]] && grep -q 'promoted r-2 to latest 100' "$T/out" \
  && pass "1. pass: rc 0, r-2 promoted to latest 100 %" || fail "1. rc=$rc st=$(cat "$T/st") $(cat "$T/out")"
has '^gcloud run services update csi-spl-hub-dev --image=example.com/hub/spool-hub:1.0.1 --no-traffic --tag=canary ' \
  && pass "1. the new revision is created with --no-traffic --tag=canary" || fail "1. update argv: $(mut)"
has '^gcloud run services update-traffic csi-spl-hub-dev --to-tags=canary=10 ' && pass "1. the canary gets the cnf share (10 %)" || fail "1. to-tags: $(mut)"
has '^gcloud run services update-traffic csi-spl-hub-dev --to-latest --remove-tags=canary ' \
  && pass "1. promote = --to-latest, tag removed (the shape heal and restart need)" || fail "1. promote: $(mut)"
! has '--to-revisions=' && [[ "$(nmut)" -eq 3 ]] && pass "1. exactly 3 mutations, no pin" || fail "1. mutations: $(mut)"
has '^curl .*https://canary---hub.example.com/v1/health' && pass "1. probes go to the tag URL, not the service URL" || fail "1. probe url"
[[ "$(grep -c 'canary---hub.example.com/v1/health' "$T/calls.log")" -eq 23 ]] \
  && pass "1. 3 probes at 0 % + 20 over 10 min every 30 s" || fail "1. probes: $(grep -c 'canary---hub.example.com/v1/health' "$T/calls.log")"
has 'revision_name="r-2"' && pass "1. Monitoring is read for the new revision" || fail "1. no Monitoring read for r-2"

# --- 2. 5xx gate ----------------------------------------------------------------
canary before 200 DRY_RUN=0 MON_r_2="100 50 0 0 5"; rc=$?
[[ $rc -eq 1 && "$(cat "$T/st")" == pinned ]] && grep -q 'FAIL 5xx 5 of 155' "$T/out" \
  && pass "2. 5 of 155 5xx: rc 1, the old revision pinned" || fail "2. rc=$rc st=$(cat "$T/st") $(cat "$T/out")"
has '^gcloud run services update-traffic csi-spl-hub-dev --to-revisions=r-1=100 --remove-tags=canary ' && ! has '--to-latest' \
  && pass "2. pin r-1=100, tag removed, never --to-latest" || fail "2. $(mut)"

# --- 3. WS gate -----------------------------------------------------------------
canary before 200 DRY_RUN=0 MON_r_2="0 40 0 0 0"; rc=$?
[[ $rc -eq 1 && "$(cat "$T/st")" == pinned ]] && grep -q 'FAIL no WS upgrade reached the canary' "$T/out" \
  && pass "3. 0 WS upgrades while 10 % of 900 predicts 100: rc 1, pinned" || fail "3. rc=$rc $(cat "$T/out")"

# --- 4. a failed 0 % probe -----------------------------------------------------
canary before "200 503" DRY_RUN=0; rc=$?
[[ $rc -eq 1 && "$(cat "$T/st")" == pinned ]] && ! has '--to-tags=' \
  && pass "4. 503 at 0 %: rc 1, pinned, no traffic ever moved" || fail "4. rc=$rc $(mut)"

# --- 5. wrong commit -------------------------------------------------------------
canary before 200 DRY_RUN=0 EXPECT_COMMIT=abc COMMIT=def; rc=$?
[[ $rc -eq 1 && "$(cat "$T/st")" == pinned ]] && ! has '--to-tags=' && grep -q "commit 'def' != abc" "$T/out" \
  && pass "5. /version commit def != abc: rc 1, pinned before any traffic" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6. Monitoring unreadable ------------------------------------------------------
canary before 200 DRY_RUN=0 MON_r_2=error; rc=$?
[[ $rc -eq 1 && "$(cat "$T/st")" == pinned ]] && grep -q 'failing closed' "$T/out" \
  && pass "6. Monitoring error: fails closed, pinned, rc 1" || fail "6. rc=$rc $(cat "$T/out")"

# --- 7. DRY_RUN default -------------------------------------------------------------
canary before 200; rc=$?
[[ $rc -eq 0 && "$(nmut)" -eq 0 && "$(cat "$T/st")" == before ]] && grep -q 'DRY_RUN would run: gcloud run services update csi-spl-hub-dev --image=' "$T/out" \
  && grep -q 'DRY_RUN would run: gcloud run services update-traffic csi-spl-hub-dev --to-tags=canary=10' "$T/out" \
  && pass "7. DRY_RUN=1 default: no mutation, both mutations printed" || fail "7. rc=$rc $(mut) $(cat "$T/out")"

# --- 8. refusals --------------------------------------------------------------------
canary split 200 DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(cat "$T/st")" == promoted ]] && grep -q 'already splits traffic (r-1:90,r-2:10), left by a killed run' "$T/out" \
  && [[ "$(mut | sed -n 1p)" == *"--to-revisions=r-1=100 --remove-tags=canary "* ]] \
  && pass "8. a split left by a killed run: pinned first, then the canary runs" || fail "8. rc=$rc $(mut) $(cat "$T/out")"
canary split 200; rc=$?
[[ $rc -eq 0 && "$(nmut)" -eq 0 ]] && grep -q 'DRY_RUN would run: gcloud run services update-traffic csi-spl-hub-dev --to-revisions=r-1=100' "$T/out" \
  && pass "8. the same under DRY_RUN: printed, no mutation" || fail "8. dry split: rc=$rc $(cat "$T/out")"
canary pinned 200 DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(cat "$T/st")" == promoted ]] && ! grep -q 'nothing to roll' "$T/out" \
  && pass "8. after a rollback (template = IMAGE_REF, r-1 pinned) a re-run retries, not 'nothing to roll'" || fail "8. pinned: rc=$rc $(cat "$T/out")"
canary before 200 DRY_RUN=0 SAME=1; rc=$?
[[ $rc -eq 0 && "$(nmut)" -eq 0 ]] && grep -q 'nothing to roll' "$T/out" && pass "8. same image: rc 0, no mutation" || fail "8. same: rc=$rc $(cat "$T/out")"
canary before 200 DRY_RUN=0 IMAGE_REF=; rc=$?
[[ $rc -eq 1 && "$(nmut)" -eq 0 ]] && pass "8. no IMAGE_REF: refused" || fail "8. no image: rc=$rc"

# --- 9. CANARY_CMD=rollback ------------------------------------------------------------
canary split 200 DRY_RUN=0 CANARY_CMD=rollback; rc=$?
[[ $rc -eq 0 && "$(cat "$T/st")" == pinned ]] && has '^gcloud run services update-traffic csi-spl-hub-dev --to-revisions=r-1=100 --remove-tags=canary ' \
  && pass "9. rollback pins the 90 % revision and drops the tag" || fail "9. rc=$rc $(mut)"
canary before 200 DRY_RUN=0 CANARY_CMD=status; rc=$?
[[ $rc -eq 0 && "$(nmut)" -eq 0 ]] && grep -q 'traffic r-1 100%' "$T/out" && pass "9. status is read only" || fail "9. status rc=$rc $(cat "$T/out")"

# --- 10. identity -------------------------------------------------------------------------
canary before 200 DRY_RUN=0
noacct="$(grep '^gcloud ' "$T/calls.log" | grep -v -- '--account=deploy@example.com')"
if [[ -n "$noacct" ]]; then fail "10. a gcloud call without --account: $(sed -n 1p <<<"$noacct")"
else pass "10. every gcloud call carries --account"; fi
noscope="$(grep '^gcloud run ' "$T/calls.log" | grep -vE -- '--project=csi-spl-dev .*--region=')"
if [[ -n "$noscope" ]]; then fail "10. a run call without --project/--region"
else pass "10. every gcloud run call carries --project and --region"; fi

# --- 11. the gate on 2026-10-16's prd numbers -----------------------------------------------
# do_spl_hub_run_metrics ENV=prd: 17:10..17:40Z (31 min, stuck) 1xx 582, 2xx 1115,
# 3xx 49, 4xx 14, 5xx 7; 16:56..17:09Z (14 min, before) 1xx 962.
gate() { env PROJ_PATH="$PROJ_ROOT" bash -c 'do_log() { :; }; source "$PROJ_PATH/src/bash/run/canary-hub-deploy.func.sh"; _chd_gate "$@"' _ "$@"; }
gate 582 1115 49 14 7 0 10 3 1 >/dev/null && pass "11. the 5xx rule alone PASSES the stuck window (7 of 1767): a no-5xx gate would not have caught it" \
  || fail "11. 5xx rule on the stuck window"
gate 0 30 1 0 0 962 10 3 1 >/dev/null && fail "11. the WS rule passed a canary with 0 upgrades" \
  || pass "11. the WS rule FAILS a canary with 0 upgrades while 10 % of 962 predicts 106"
gate 1 0 0 0 0 30 10 3 1 >/dev/null && pass "11. a share predicting < 5 upgrades never fails on WS (n too small)" || fail "11. small n"

# --- 12. cnf knobs ----------------------------------------------------------------------------
knob() { printf 'env:\n  hub:\n    service_name: s\n    cloud_run:\n      canary: %s\n' "$1" >"$T/k.yaml"
  env PROJ_PATH="$PROJ_ROOT" SPL_CNF="$T/k.yaml" ENV=dev bash -c 'do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/canary-hub-deploy.func.sh"; _chd_cnf && echo "$CHD_PCT $CHD_MIN $CHD_TAG"'; }
[[ "$(knob '{}')" == "10 10 canary" ]] && pass "12. defaults: 10 %, 10 min, tag canary" || fail "12. defaults: $(knob '{}')"
grep -q 'percent must be 1..50' <<<"$(knob '{percent: 60}')" && pass "12. percent 60 refused" || fail "12. percent 60"
grep -q 'is not a Cloud Run tag' <<<"$(knob '{tag: Bad_Tag}')" && pass "12. a bad tag refused" || fail "12. bad tag"
grep -q 'positive integers' <<<"$(knob '{minutes: 0}')" && pass "12. minutes 0 refused" || fail "12. minutes 0"

# --- 13. workflow 20 ------------------------------------------------------------------------------
grep -q 'canary=$(yq -r ".env.hub.cloud_run.canary.enabled // false"' "$WF" && pass "13. wf 20 reads cnf hub.cloud_run.canary.enabled" || fail "13. no canary cnf read in $WF"
grep -qF 'DRY_RUN=0 GCP_ACCOUNT="$DEPLOY_SA" IMAGE_REF="$IMAGE_REF" EXPECT_COMMIT="$GITHUB_SHA" \' "$WF" && grep -qF './csi-spl-orc/run -a do_canary_hub_deploy | tee' "$WF" \
  && pass "13. wf 20 runs do_canary_hub_deploy with the minted image and the commit" || fail "13. no canary run in $WF"
# the owner's go is per env: dev on (HUM-10 msg 828eb2f5, 2026-10-18), all + prd off until a prd go
v="$(yq -r '.env.hub.cloud_run.canary.enabled // "unset"' "$APP_ROOT/csi-spl-cnf/csi-spl/dev.env.yaml")"
[[ "$v" == true ]] && pass "13. cnf dev: canary enabled (owner go 828eb2f5)" || fail "13. cnf dev canary.enabled=$v"
for e in all prd; do
  v="$(yq -r '.env.hub.cloud_run.canary.enabled // "unset"' "$APP_ROOT/csi-spl-cnf/csi-spl/$e.env.yaml")"
  [[ "$v" == false || "$v" == unset ]] && pass "13. cnf $e: canary not enabled until the owner's go" || fail "13. cnf $e canary.enabled=$v"
done

[[ $fails -eq 0 ]] && echo "PASS: all canary-hub-deploy assertions" || { echo "FAILED: $fails"; exit 1; }
