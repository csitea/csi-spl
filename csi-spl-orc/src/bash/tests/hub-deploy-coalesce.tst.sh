#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5641 (spec 175 task 5.10) -- the proof count of hub rollouts.
#   1. hub-deploy-coalesce.sh per-day turns revision creation times into
#      "<day> <count>" lines, oldest first, and refuses a non-timestamp
#   2. hold: the seconds left of the window since the newest revision; 0 once
#      it has passed, never more than one window (clock skew), off at 0 min,
#      refuses bad input
#   2b. the 2-hour default and hold-version (a hub /version body's .built_at;
#      an unreadable one never holds); 2c. workflow 20 wires it, prd on dev's
#   3. do_hub_revisions_per_day lists the env's cnf service as the pinned
#      account, read-only (one `gcloud run revisions list`, no update), and
#      prints the per-day count; a failed list is a FATAL, not an empty count
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
S="$PROJ_ROOT/src/bash/scripts/hub-deploy-coalesce.sh"
A="$PROJ_ROOT/src/bash/run/hub-revisions-per-day.func.sh"
[[ -f "$S" ]] || { fail "no $S"; exit 1; }
[[ -f "$A" ]] || { fail "no $A"; exit 1; }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi; }

# 1. per-day
out="$(printf '%s\n' 2026-11-15T19:40:20.267223Z 2026-11-14T23:46:46.344116Z 2026-11-15T01:03:38Z '' 2026-11-14T08:33:15Z | bash "$S" per-day)"
check "$out" $'2026-11-14 2\n2026-11-15 2' "per-day: counts revisions per UTC day, oldest first"
check "$(bash "$S" per-day </dev/null)" "" "per-day: no revisions, no lines"
printf 'not-a-time\n' | bash "$S" per-day >/dev/null 2>&1; check "$?" 2 "per-day: a non-timestamp is refused"

# 2. hold
now=1763236800
check "$(HUB_DEPLOY_COALESCE_MIN=15 bash "$S" hold $((now - 300)) "$now")" 600 "hold: 5 min after a roll, 10 min of a 15-min window left"
check "$(HUB_DEPLOY_COALESCE_MIN=15 bash "$S" hold $((now - 900)) "$now")" 0 "hold: the window has passed, roll now"
check "$(HUB_DEPLOY_COALESCE_MIN=15 bash "$S" hold $((now + 7200)) "$now")" 900 "hold: a future-stamped revision holds one window at most"
check "$(HUB_DEPLOY_COALESCE_MIN=0 bash "$S" hold $((now - 1)) "$now")" 0 "hold: window 0 turns it off"
bash "$S" hold "" "$now" >/dev/null 2>&1; check "$?" 2 "hold: no last epoch is refused"
HUB_DEPLOY_COALESCE_MIN=x bash "$S" hold "$now" "$now" >/dev/null 2>&1; check "$?" 2 "hold: a non-numeric window is refused"

# 2b. the owner's 2-hour hold (poll 9f948a6a pick B): the default window, and
# hold-version reading a hub GET /version body's .built_at
check "$(env -u HUB_DEPLOY_COALESCE_MIN bash "$S" hold $((now - 1800)) "$now")" 5400 "hold: the default window is 120 min"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
check "$(printf '{"commit":"abc","built_at":"%s"}' "$(iso $((now - 1800)))" | env -u HUB_DEPLOY_COALESCE_MIN bash "$S" hold-version "$now")" 5400 \
  "hold-version: a build served for 30 min holds 90 more"
check "$(printf '{"commit":"abc","built_at":"%s"}' "$(iso $((now - 7800)))" | env -u HUB_DEPLOY_COALESCE_MIN bash "$S" hold-version "$now")" 0 \
  "hold-version: a build served for 130 min rolls now"
check "$(printf '{"commit":"abc"}' | bash "$S" hold-version "$now" 2>/dev/null)" 0 "hold-version: no .built_at never holds"
check "$(printf 'junk' | bash "$S" hold-version "$now" 2>/dev/null)" 0 "hold-version: a junk body never holds"
check "$(bash "$S" hold-version "$now" </dev/null 2>/dev/null)" 0 "hold-version: no body never holds"

# 2c. workflow 20 wires the hold into its forward guard, prd also waits on dev's
W="$PROJ_ROOT/../.github/workflows/20_hub-build-deploy.yml"
if [[ -f "$W" ]]; then
  grep -q "HUB_DEPLOY_COALESCE_MIN: \${{ vars.HUB_DEPLOY_COALESCE_MIN || '120' }}" "$W" \
    && pass "workflow 20: the hold window is a repo var, default 120" || fail "workflow 20: no HUB_DEPLOY_COALESCE_MIN default 120"
  [[ "$(grep -c 'hub-deploy-coalesce.sh hold-version' "$W")" -ge 2 ]] \
    && pass "workflow 20: the guard reads its env's and (prd) dev's hold" || fail "workflow 20: hold-version not called for both envs"
  grep -q 'DEV_API_FQDN: \${{ steps.cfg.outputs.dev_api_fqdn }}' "$W" \
    && pass "workflow 20: the prd leg gets dev's /version host" || fail "workflow 20: no DEV_API_FQDN"
else
  echo "SKIP: section 2c, no $W"
fi

# 3. the action, its cloud helpers stubbed, gcloud a stub on PATH
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<'SH'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
[ -n "$STUB_FAIL" ] && { echo "PERMISSION_DENIED: no run.revisions.list" >&2; exit 1; }
printf '%s\n' 2026-11-15T19:40:20Z 2026-11-15T18:27:21Z 2026-11-14T08:33:15Z
SH
chmod +x "$T/bin/gcloud"
printf 'env:\n  hub:\n    service_name: hub-svc-x\n' >"$T/cnf.yaml"
run_action() {
  PATH="$T/bin:$PATH" STUB_LOG="$T/log" PROJ_PATH="$PROJ_ROOT" bash -c '
    do_log() { echo "$*"; }
    do_require_bin() { command -v "$1" >/dev/null; }
    do_spl_cloud_cnf() { SPL_CNF="$CNF" SPL_PROJECT=proj-x SPL_REGION=region-x; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa-x@proj-x; }
    source "$1"; do_hub_revisions_per_day' _ "$A"
}
command -v yq >/dev/null || { echo "SKIP: section 3 needs yq"; }
if command -v yq >/dev/null; then
  : >"$T/log"
  out="$(CNF="$T/cnf.yaml" ENV=dev run_action 2>&1)"
  check "$out" $'2026-11-14 1\n2026-11-15 2' "action: prints revisions per day"
  check "$(wc -l <"$T/log")" 1 "action: exactly one gcloud call"
  grep -q -- 'run revisions list --service=hub-svc-x --project=proj-x --region=region-x --account=sa-x@proj-x --limit=200' "$T/log" \
    && pass "action: lists the cnf service as the pinned account, LIMIT 200" || fail "action: wrong call: $(cat "$T/log")"
  grep -qE 'update|delete|deploy' "$T/log" && fail "action: mutating call made" || pass "action: read-only"
  out="$(CNF="$T/cnf.yaml" ENV=dev STUB_FAIL=1 run_action 2>&1)"; rc=$?
  [[ $rc -ne 0 && "$out" == *"FATAL cannot list the revisions of hub-svc-x"* ]] \
    && pass "action: a failed list is a FATAL (rc $rc)" || fail "action: failed list rc=$rc out=$out"
  out="$(CNF="$T/cnf.yaml" ENV=dev LIMIT=0 run_action 2>&1)"; rc=$?
  [[ $rc -ne 0 && "$out" == *"FATAL LIMIT"* ]] && pass "action: LIMIT 0 is refused" || fail "action: LIMIT 0 rc=$rc"
fi

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
