#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: specs/024 -- the tenant host reconcile (40) stays inside the
#          owner's rules: REVIVED (owner option A 2026-09-30, 047 B5), so a
#          schedule every 15 min plus dispatch; one run per env
#          (concurrency group per env, never cancelled mid-apply); dev before
#          prd (max-parallel 1, matrix order); only the existing per-env key
#          secrets GCP_KEY_CSI_SPL_<ENV> (+ the private overlay, SPL-1874) are read; terraform only through the
#          orc make targets (no terraform binary / setup-terraform / host
#          tf run); the apply is gated on open rows and runs the named action;
#          the tf stack (tpl-gen, make do-setup-app-inf) is built only when a
#          row needs terraform (apply != 0: a mapped row is only checked);
#          the action it names exists in csi-spl-orc.
#          CONTROL: a copy with the schedule removed, a planted extra secret
#          and a host terraform step is reported by the same checks.
#          SPL-5008: the workflow's REAL key step for the prd job, then the REAL
#          order gate, plan and tf init (terraform and tfswitch are stubs, the
#          stub init fails on an unreadable key as terraform does, checked
#          against a real terraform when one is installed): the gate's dev plan
#          finds its key and passes dev clean, and still refuses dev pending,
#          dev failed and an empty dev secret. CONTROL: the key step written
#          for the dev job only is refused the way run 42377877602 was.
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
sched = [str(x.get("cron", "")) for x in (on.get("schedule") or [])]
if sched != ["7,22,37,52 * * * *"] or "workflow_dispatch" not in on: bad.append("revived: must run every 15 min (7,22,37,52) plus dispatch, no schedule found")
j = w["jobs"]["reconcile"]
c = j.get("concurrency") or {}
if "matrix.environment" not in str(c.get("group", "")) or c.get("cancel-in-progress") is not False:
    bad.append("concurrency is not one group per env with cancel-in-progress false")
st = j["strategy"]
if st.get("max-parallel") != 1 or st["matrix"]["environment"] != ["dev", "prd"]: bad.append("not dev then prd, one at a time")
for s in re.findall(r"secrets(?:\.[A-Za-z0-9_]+|\[[^\]]*\])", raw):
    if not re.search(r"GCP_KEY_CSI_SPL_(DEV|PRD|\{0\})|SPL_PRIVATE_CNF_YAML\b", s): bad.append("reads another secret: " + s)
for step in j["steps"]:
    run = step.get("run", "") or ""
    uses = step.get("uses", "") or ""
    if "setup-terraform" in uses or re.search(r"(^|\s)terraform\s", run): bad.append("host terraform: " + step.get("name", uses))
applies = [s for s in j["steps"] if "DRY_RUN" in str(s.get("env", {}))]
if not applies or any("do_spl_tenant_host_reconcile" not in s.get("run", "") for s in applies): bad.append("the apply is not the named action")
if any("steps.open.outputs.open" not in str(s.get("if", "")) for s in applies): bad.append("the apply is not gated on open rows")
for s in j["steps"]:
    if ("do_setup_tpl_gen" in str(s.get("run", "")) or "do-setup-app-inf" in str(s.get("run", ""))) and "steps.open.outputs.apply" not in str(s.get("if", "")):
        bad.append("the tf stack is not gated on apply: " + s.get("name", ""))
print("\n".join(bad))
PY
}

out=$(check "$WF")
[[ -z "$out" ]] && pass "40 keeps the rules (revived: every 15 min + dispatch, per-env concurrency, dev->prd, key secrets only, make path only, gated named action)" ||
  fail "40: $out"
grep -q '^do_spl_tenant_host_reconcile()' "$APP_ROOT/csi-spl-orc/src/bash/run/spl-tenant-host-reconcile.func.sh" &&
  pass "the named action exists in csi-spl-orc" || fail "do_spl_tenant_host_reconcile is missing"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
python3 - "$WF" "$T/bad.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace("  schedule:\n    - cron: \"7,22,37,52 * * * *\"\n", "", 1)
s = s.replace("if: steps.open.outputs.apply != '' && steps.open.outputs.apply != '0'", "if: steps.open.outputs.open != ''")
s = s.replace("      - name: Drop the keys", "      - name: planted\n        env:\n          X: ${{ secrets.OTHER_TOKEN }}\n        run: terraform apply -auto-approve\n\n      - name: Drop the keys", 1)
open(sys.argv[2], "w").write(s)
PY
out=$(check "$T/bad.yml")
grep -q 'another secret' <<<"$out" && grep -q 'host terraform' <<<"$out" && grep -q 'no schedule' <<<"$out" &&
  grep -q 'tf stack is not gated on apply' <<<"$out" &&
  pass "CONTROL: a removed schedule, a planted secret, a host terraform step and an ungated tf stack are all reported" || fail "CONTROL missed: $out"

# --- SPL-5008: a prd add passes the order gate honestly -----------------------
IAC="$APP_ROOT/csi-spl-iac"
# keystep <workflow> <home> <dev key> : the workflow's own key step, as the prd job runs it
keystep() {
  python3 -c '
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for s in w["jobs"]["reconcile"]["steps"] if s.get("name", "").startswith("Env SA keys")))' "$1" >"$T/keystep.sh"
  env -i PATH="$PATH" HOME="$2" ENV=prd KEY_DEV="$3" KEY_PRD='{"client_email":"prd@example.test"}' PRIVATE_CNF='x: 1' bash "$T/keystep.sh"
}

# the fixture a dev plan reads: one step, its cnf, no placeholder
FX="$T/fx"; STEP_X=052-gcs-workspace-docs
mkdir -p "$FX/csi-spl-iac/src/terraform/$STEP_X" "$FX/csi-spl-iac/src/terraform/modules" "$FX/csi-spl-iac/dat/log" "$FX/csi-spl-cnf/csi-spl/dev/tf"
echo '{"env":{"gcp":{"gcp_project":"csi-spl-dev"},"versions":{"terraform_version":"1.9.8"},"steps":{}}}' >"$FX/csi-spl-cnf/csi-spl/dev.env.json"
echo 'workspaces = ["t1"]' >"$FX/csi-spl-cnf/csi-spl/dev/tf/$STEP_X.vars.tfvars"
echo 'bucket = "example-none"' >"$FX/csi-spl-cnf/csi-spl/dev/tf/$STEP_X.backend-config.tfvars"
git init -q "$FX" && git -C "$FX" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m t
mkdir -p "$T/stub"
cat >"$T/stub/terraform" <<'S'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in init)
  [[ -r "$GOOGLE_APPLICATION_CREDENTIALS" ]] || { echo "│ Error: storage.NewClient() failed: cannot read $GOOGLE_APPLICATION_CREDENTIALS"; exit 1; }
  echo "$GOOGLE_APPLICATION_CREDENTIALS" >>"$CALLS"; exit 0 ;;
  plan) echo "plan" >>"$CALLS"; [[ "$STUB_PLAN_RC" == 0 ]] && echo "No changes."; exit "$STUB_PLAN_RC" ;;
esac; done
S
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/stub/tfswitch"
chmod +x "$T/stub/terraform" "$T/stub/tfswitch"

# real_gate <home> <plan rc>: the REAL gate, plan and tf init of a prd apply
real_gate() {
  env -i PATH="$T/stub:$PATH" HOME="$1" CALLS="$T/calls" STUB_PLAN_RC="$2" PROJ_PATH="$FX/csi-spl-iac" APP_PATH="$FX" ORG=csi APP=spl \
    BASE_PATH="$T" ORG_PATH="$T" ENV=prd STEP="$STEP_X" ACTION=provision ENV_ORDER_CACHE_DIR="$T/cache" ENV_ORDER_CACHE_MINUTES=0 \
    SPL_PRIVATE_CNF=/nonexistent IAC="$IAC" bash -c '
    cd "$PROJ_PATH" || exit 9
    do_log() { echo "$*"; }
    quit_on() { :; }
    for f in "$IAC"/lib/bash/funcs/*.func.sh; do source "$f"; done
    for f in tf-init check-dev-leads-prd tf-plan-pending; do source "$IAC/src/bash/run/$f.func.sh"; done
    do_check_dev_leads_prd'
}

H="$T/h1"; mkdir -p "$H"; DEV_KEY='{"client_email":"dev@example.test"}'
keystep "$WF" "$H" "$DEV_KEY" || fail "the key step failed for the prd job"
[[ -s "$H/.gcp/.csi/key-csi-spl-dev.json" && -s "$H/.gcp/.csi/key-csi-spl-prd.json" ]] &&
  pass "the prd job's key step writes the dev key the gate's dev plan needs" || fail "prd job keys: $(ls -A "$H/.gcp/.csi" 2>&1 | tr '\n' ' ')"
: >"$T/calls"; out=$(real_gate "$H" 0 2>&1); rc=$?
[[ $rc == 0 ]] && grep -q 'allowed dev=clean' <<<"$out" && grep -q 'key-csi-spl-dev.json' "$T/calls" &&
  pass "the real gate in the prd job plans dev with the dev key and passes dev clean" || fail "gate after the keys: rc=$rc calls=[$(cat "$T/calls")] :: $out"
out=$(real_gate "$H" 2 2>&1); rc=$?
[[ $rc == 3 ]] && grep -q '^REFUSED:.*pending changes' <<<"$out" && pass "not weakened: dev pending is still refused (rc 3)" || fail "dev pending: rc=$rc :: $out"
out=$(real_gate "$H" 1 2>&1); rc=$?
[[ $rc == 1 ]] && grep -q '^REFUSED:.*unknown' <<<"$out" && pass "not weakened: a failed dev plan is still refused (rc 1)" || fail "dev failed: rc=$rc :: $out"

# an empty dev secret: no empty key file, and the gate fails closed
H="$T/h2"; mkdir -p "$H"
keystep "$WF" "$H" "" || fail "the key step failed on an empty dev secret"
[[ ! -e "$H/.gcp/.csi/key-csi-spl-dev.json" ]] && pass "an empty dev secret writes no dev key file" || fail "an empty dev key file was written"
out=$(real_gate "$H" 0 2>&1); rc=$?
[[ $rc == 1 ]] && grep -q '^REFUSED:.*unknown' <<<"$out" && pass "no dev key: the gate refuses, never passes" || fail "no dev key: rc=$rc :: $out"

# CONTROL: the key step as run 42377877602 ran it, dev job only
sed -E 's/^( *)if \[\[ -n "\$KEY_DEV" \]\]; then/\1if [[ "$ENV" == dev ]]; then/' "$WF" >"$T/devonly.yml"
H="$T/h3"; mkdir -p "$H"
keystep "$T/devonly.yml" "$H" "$DEV_KEY" || fail "CONTROL: the key step failed"
out=$(real_gate "$H" 0 2>&1); rc=$?
[[ $rc == 1 && ! -e "$H/.gcp/.csi/key-csi-spl-dev.json" ]] && grep -q "TF_PLAN dev $STEP_X error.* plan failed" <<<"$out" && grep -q '^REFUSED:' <<<"$out" &&
  pass "CONTROL: a dev key written for the dev job only refuses as run 42377877602 did (plan failed, no summary)" || fail "CONTROL: rc=$rc :: $out"

# the stub's init is what terraform does: a real init on a missing key, no network reached
real_tf="$(command -v terraform || true)"
if [[ -n "$real_tf" ]]; then
  mkdir -p "$T/tf"; printf 'terraform {\n  backend "gcs" {}\n}\n' >"$T/tf/main.tf"
  out=$(env -u GOOGLE_CREDENTIALS HOME="$T" GOOGLE_APPLICATION_CREDENTIALS="$T/tf/none.json" timeout 60 "$real_tf" -chdir="$T/tf" init -input=false -backend-config=bucket=example-none 2>&1); rc=$?
  [[ $rc != 0 ]] && grep -q 'GOOGLE_APPLICATION_CREDENTIALS' <<<"$out" && pass "a real terraform init fails on a missing key, as the stub does" || fail "real terraform: rc=$rc :: $out"
else
  echo "SKIP: no terraform on this box, the stub's init is not compared with a real one"
fi

[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
