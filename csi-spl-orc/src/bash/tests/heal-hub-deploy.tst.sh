#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_heal_hub_deploy (option A of the 2026-10-04 prd 429 incident,
#          task aa35699c) forces at most ONE fresh hub revision, and only on a
#          429 streak.
#   1. healthy (every /v1/health 200): rc 0, the whole window probed, NO
#      `run services update`
#   2. a 429 streak, then 200 after the fresh revision: exactly ONE update,
#      --update-env-vars=SPOOL_HUB_RESTART_AT=<UTC ts> (do_gcp_hub_restart's
#      update), rc 0
#   3. still 429 after it: exactly ONE update, rc 1 (the job fails)
#   4. DRY_RUN=1 (the default) on a streak: no update, the would-run printed, rc 1
#   5. unhealthy without a 429 streak (503): no update, rc 1
#   6. isolated 429s below the streak: no update, rc 0
#   7. every gcloud call carries --account, --project and --region
#   8. workflow 20 runs it (DRY_RUN=0, as the deploy SA) after the roll and
#      before the verify, in the one deploy job both envs run
# gcloud, curl and sleep are stubs; the curl stub answers the codes listed in
# $CODES one per call (the last repeats), and the update swaps in $AFTER.
# CONTROL: the stubs record every call, so "no update" means not made.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
WF="$APP_ROOT/.github/workflows/20_hub-build-deploy.yml"

mkdir -p "$T/stub"
cat >"$T/stub/gcloud" <<'EOF'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  "run services describe"*) echo "https://hub.example.com" ;;
  "run services update"*) [ -n "${AFTER:-}" ] && cp "$AFTER" "$CODES" ;;
  *) exit 1 ;;
esac
exit 0
EOF
cat >"$T/stub/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$STUB_LOG"
code=$(sed -n 1p "$CODES")
[ "$(wc -l <"$CODES")" -gt 1 ] && sed -i 1d "$CODES"
printf %s "$code"
EOF
printf '#!/bin/sh\n:\n' >"$T/stub/sleep"
chmod +x "$T/stub/"*

# heal <codes> <after-codes or ""> [VAR=value...] -> rc; out in $T/out
heal() {
  local codes="$1" after="$2"; shift 2
  : >"$T/calls.log"
  printf '%s\n' $codes >"$T/codes"
  if [[ -n "$after" ]]; then printf '%s\n' $after >"$T/after"; else rm -f "$T/after"; fi
  local a=(); [[ -n "$after" ]] && a=(AFTER="$T/after")
  env -u DRY_RUN PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev CODES="$T/codes" GCP_ACCOUNT=deploy@example.com "${a[@]}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_heal_hub_deploy' >"$T/out" 2>&1
}
updates() { grep -c '^gcloud run services update' "$T/calls.log"; }
probes() { grep -c '^curl ' "$T/calls.log"; }

# --- 1. healthy -------------------------------------------------------------------
heal "200" "" DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(updates)" -eq 0 && "$(probes)" -eq 12 ]] && grep -q 'no extra revision' "$T/out" \
  && pass "1. healthy: rc 0, 12 probes over 60 s, no extra revision" || fail "1. rc=$rc updates=$(updates) probes=$(probes) $(cat "$T/out")"
grep -q 'curl .*https://hub.example.com/v1/health' "$T/calls.log" && pass "1. probes <service url>/v1/health" || fail "1. url: $(cat "$T/calls.log")"

# --- 2. streak, healed --------------------------------------------------------------
heal "200 429 429 429" "200" DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(updates)" -eq 1 ]] && grep -q 'healed by one fresh revision' "$T/out" \
  && pass "2. 429 streak then 200: exactly one fresh revision, rc 0" || fail "2. rc=$rc updates=$(updates) $(cat "$T/out")"
grep -qE '^gcloud run services update csi-spl-hub-dev .*--update-env-vars=SPOOL_HUB_RESTART_AT=[0-9]{8}T[0-9]{6}Z( |$)' "$T/calls.log" \
  && pass "2. the update is do_gcp_hub_restart's: SPOOL_HUB_RESTART_AT=<UTC ts> on the cnf service" || fail "2. update argv: $(grep update "$T/calls.log")"
! grep -q -- '--image' "$T/calls.log" && pass "2. the image is not touched" || fail "2. --image in $(cat "$T/calls.log")"

# --- 3. still bad -------------------------------------------------------------------
heal "429" "429" DRY_RUN=0; rc=$?
[[ $rc -eq 1 && "$(updates)" -eq 1 ]] && grep -q 'STILL 429 after the one fresh revision' "$T/out" \
  && pass "3. still 429 after the restart: exactly one update, rc 1" || fail "3. rc=$rc updates=$(updates) $(cat "$T/out")"

# --- 4. dry run ---------------------------------------------------------------------
heal "429" ""; rc=$?
[[ $rc -eq 1 && "$(updates)" -eq 0 ]] && grep -q 'DRY_RUN would run: gcloud run services update csi-spl-hub-dev' "$T/out" \
  && pass "4. DRY_RUN default: streak reported, no update, rc 1" || fail "4. rc=$rc updates=$(updates) $(cat "$T/out")"

# --- 5. unhealthy, no streak --------------------------------------------------------
heal "503" "" DRY_RUN=0; rc=$?
[[ $rc -eq 1 && "$(updates)" -eq 0 ]] && grep -q 'without a 429 streak (last /v1/health 503)' "$T/out" \
  && pass "5. 503 throughout: no restart, rc 1" || fail "5. rc=$rc updates=$(updates) $(cat "$T/out")"

# --- 6. isolated 429s ---------------------------------------------------------------
heal "429 429 200 429 200" "" DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(updates)" -eq 0 ]] && pass "6. 429s below the streak: no restart, rc 0" || fail "6. rc=$rc updates=$(updates) $(cat "$T/out")"

# --- 7. identity --------------------------------------------------------------------
heal "429" "200" DRY_RUN=0
n=$(grep -c '^gcloud ' "$T/calls.log")
m=$(grep '^gcloud ' "$T/calls.log" | grep -- '--account=deploy@example.com' | grep -- '--project=csi-spl-dev' | grep -c -- '--region=')
[[ "$n" -ge 2 && "$n" == "$m" ]] && pass "7. every gcloud call ($n) carries --account, --project, --region" || fail "7. $n calls, $m pinned: $(cat "$T/calls.log")"

# --- 8. workflow wiring -------------------------------------------------------------
roll=$(grep -n 'name: Roll the 030 service' "$WF" | cut -d: -f1)
step=$(grep -n 'name: Heal a stuck rollout' "$WF" | cut -d: -f1)
ver=$(grep -n 'name: Verify the service runs the minted image' "$WF" | cut -d: -f1)
[[ -n "$roll" && -n "$step" && -n "$ver" && "$roll" -lt "$step" && "$step" -lt "$ver" ]] \
  && pass "8. workflow 20: the heal step sits between the roll and the verify" || fail "8. order roll=$roll heal=$step verify=$ver"
body=$(sed -n "${step},${ver}p" "$WF")
grep -q 'DRY_RUN=0 .*GCP_ACCOUNT="\$DEPLOY_SA" .*-a do_heal_hub_deploy' <<<"$body" \
  && pass "8. ... it runs do_heal_hub_deploy with DRY_RUN=0 as the deploy SA" || fail "8. step body: $body"
! grep -qE 'matrix.environment *==|ENV *== *.?(dev|prd)' <<<"$body" \
  && pass "8. ... the same step for dev and prd (no per-env branch)" || fail "8. env branch in: $body"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
