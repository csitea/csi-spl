#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: specs/024 -- the tenant host reconcile (40) stays inside the
#          owner's rules: PAUSED (owner 2026-09-19 16:43Z, tenant from
#          identity), so dispatch only and NO schedule; one run per env
#          (concurrency group per env, never cancelled mid-apply); dev before
#          prd (max-parallel 1, matrix order); only the existing per-env key
#          secrets GCP_KEY_CSI_SPL_<ENV> are read; terraform only through the
#          orc make targets (no terraform binary / setup-terraform / host
#          tf run); the apply is gated on open rows and runs the named action;
#          the action it names exists in csi-spl-orc.
#          CONTROL: a copy with a planted extra secret and a host terraform
#          step is reported by the same checks.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
WF="$APP_ROOT/.github/workflows/40_tenant-host-reconcile.yml"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
[[ -f "$WF" ]] || { echo "FAIL: missing $WF"; exit 1; }

# check <file> -> prints one line per violation
check() {
  python3 - "$1" <<'PY'
import re, sys, yaml
p = sys.argv[1]
raw = open(p).read()
w = yaml.safe_load(raw)
on = w.get(True) or w.get("on")
bad = []
if on.get("schedule") or "workflow_dispatch" not in on: bad.append("paused: must be dispatch only, no schedule")
j = w["jobs"]["reconcile"]
c = j.get("concurrency") or {}
if "matrix.environment" not in str(c.get("group", "")) or c.get("cancel-in-progress") is not False:
    bad.append("concurrency is not one group per env with cancel-in-progress false")
st = j["strategy"]
if st.get("max-parallel") != 1 or st["matrix"]["environment"] != ["dev", "prd"]: bad.append("not dev then prd, one at a time")
for s in re.findall(r"secrets(?:\.[A-Za-z0-9_]+|\[[^\]]*\])", raw):
    if not re.search(r"GCP_KEY_CSI_SPL_(DEV|PRD|\{0\})", s): bad.append("reads another secret: " + s)
for step in j["steps"]:
    run = step.get("run", "") or ""
    uses = step.get("uses", "") or ""
    if "setup-terraform" in uses or re.search(r"(^|\s)terraform\s", run): bad.append("host terraform: " + step.get("name", uses))
applies = [s for s in j["steps"] if "DRY_RUN" in str(s.get("env", {}))]
if not applies or any("do_spl_tenant_host_reconcile" not in s.get("run", "") for s in applies): bad.append("the apply is not the named action")
if any("steps.open.outputs.open" not in str(s.get("if", "")) for s in applies): bad.append("the apply is not gated on open rows")
print("\n".join(bad))
PY
}

out=$(check "$WF")
[[ -z "$out" ]] && pass "40 keeps the rules (paused: dispatch only, per-env concurrency, dev->prd, key secrets only, make path only, gated named action)" ||
  fail "40: $out"
grep -q '^do_spl_tenant_host_reconcile()' "$APP_ROOT/csi-spl-orc/src/bash/run/spl-tenant-host-reconcile.func.sh" &&
  pass "the named action exists in csi-spl-orc" || fail "do_spl_tenant_host_reconcile is missing"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$WF" "$T/bad.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace("on:\n  workflow_dispatch:", "on:\n  schedule:\n    - cron: \"*/10 * * * *\"\n  workflow_dispatch:", 1)
s = s.replace("      - name: Drop the keys", "      - name: planted\n        env:\n          X: ${{ secrets.OTHER_TOKEN }}\n        run: terraform apply -auto-approve\n\n      - name: Drop the keys", 1)
open(sys.argv[2], "w").write(s)
PY
out=$(check "$T/bad.yml")
grep -q 'another secret' <<<"$out" && grep -q 'host terraform' <<<"$out" && grep -q 'no schedule' <<<"$out" &&
  pass "CONTROL: a re-added schedule, a planted secret and a host terraform step are all reported" || fail "CONTROL missed: $out"

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
