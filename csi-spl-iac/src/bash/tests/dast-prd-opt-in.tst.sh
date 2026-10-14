#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: workflow 68 (DAST) scans dev by default and prd only on an explicit,
#          confirmed dispatch (devops guide section 16, row T2): the schedule and
#          a bare dispatch target dev.<BASE_DOMAIN>; environment=prd without
#          confirm_prd=prd fails before any request; a confirmed prd run targets
#          the apex; ZAP carries a 5 req/s rate-limit rule on the target host.
#          Runs the workflow's own gate steps against a fake cnf; no network.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF="$APP_ROOT/.github/workflows/68_dast.yml"

fails=0
[[ -f "$WF" ]] || { echo "FAIL: no workflow at $WF"; exit 1; }
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null \
  || { echo "FAIL: python3 + yaml required"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/csi-spl-cnf/csi-spl"
printf 'env:\n  dns:\n    BASE_DOMAIN: example.test\n' > "$T/csi-spl-cnf/csi-spl/all.env.yaml"

# step <job> <step name prefix> -> the step's run script into $T/<job>.sh
step() {
  python3 - "$WF" "$1" "$2" > "$T/$1.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for s in wf["jobs"][sys.argv[2]]["steps"]:
    if s.get("name", "").startswith(sys.argv[3]):
        print(s["run"]); break
PY
  [[ -s "$T/$1.sh" ]] || { fail "$1: no step '$2'"; return 1; }
}
step zap "Derive target" || exit 1
step headers "prd opt-in gate" || exit 1

# run <job> <TARGET_ENV> <CONFIRM_PRD> -> rc; url in $T/out
run() {
  : > "$T/out"
  (cd "$T" && TARGET_ENV="$2" CONFIRM_PRD="$3" GITHUB_OUTPUT="$T/out" bash "$T/$1.sh") >/dev/null 2>&1
}
url() { sed -n 's/^url=//p' "$T/out"; }

run zap dev "" && [[ "$(url)" == https://dev.example.test ]] \
  && pass "dev (the default) scans dev.<BASE_DOMAIN>" || fail "dev target: rc or url '$(url)'"
run zap prd "" ; rc=$?
[[ $rc -ne 0 && -z "$(url)" ]] && pass "prd without confirm_prd fails, no target" || fail "unconfirmed prd ran (rc=$rc url='$(url)')"
run zap prd yes ; rc=$?
[[ $rc -ne 0 && -z "$(url)" ]] && pass "prd with a wrong confirm fails" || fail "confirm 'yes' accepted (rc=$rc)"
run zap prd prd && [[ "$(url)" == https://example.test ]] \
  && pass "confirmed prd scans the apex" || fail "confirmed prd: url '$(url)'"
run zap stg prd ; [[ $? -ne 0 ]] && pass "unknown environment refused" || fail "environment stg accepted"
run headers prd "" ; [[ $? -ne 0 ]] && pass "headers job refuses unconfirmed prd" || fail "headers job ran unconfirmed prd"
run headers prd prd && pass "headers job accepts confirmed prd" || fail "headers job refused confirmed prd"

# The defaults: dispatch input defaults to dev; a schedule (no inputs) is dev.
python3 - "$WF" <<'PY' && pass "input environment: choice dev|prd, default dev" || fail "environment input not choice dev|prd default dev"
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get("on", wf.get(True))
i = on["workflow_dispatch"]["inputs"]["environment"]
sys.exit(0 if i["default"] == "dev" and i["options"] == ["dev", "prd"] else 1)
PY
grep -qF "TARGET_ENV: \${{ inputs.environment || 'dev' }}" "$WF" \
  && pass "a run with no inputs (schedule) targets dev" || fail "TARGET_ENV does not default to dev"

# Rate cap: rule 0 on the derived host, 5 req/s, enabled.
co=$(grep -E '^[[:space:]]*cmd_options:' "$WF")
for want in 'rule(0).enabled=true' 'rule(0).matchStr=${{ steps.tgt.outputs.host }}' 'rule(0).reqsPerSec=5' 'spider.threadCount=2'; do
  grep -qF -- "$want" <<<"$co" && pass "ZAP cmd_options carries $want" || fail "ZAP cmd_options lacks $want"
done

[[ "$fails" -eq 0 ]] && echo "PASS: all dast-prd-opt-in.tst.sh assertions"
exit "$fails"
