#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: perf round 4, C5 - build once instead of rebuilding every run.
# What must hold in 10_ci-quality.yml:
#   1. wui-generate runs `pnpm run generate` once and uploads .output/public
#      as the wui-mock-bundle artifact; the bundle budget runs AFTER the
#      upload (a budget miss must not stop the browser tests, CLE-35000)
#   2. wui-e2e needs wui-generate, gates on the upload having succeeded (not
#      on the whole job: the budget step may be red), never generates itself,
#      and downloads the artifact into csi-spl-wui/.output/public before the
#      e2e step
#   3. gate-health still waits on wui-generate
#   CONTROLS: a shard that generates again, a shard gated on the generate
#   job's success, and a budget moved before the upload are each reported.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W="$APP_ROOT/.github/workflows"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# wf10_problems <wf file> -> one line per broken rule (empty = ok)
wf10_problems() {
  python3 - "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); j = wf["jobs"]; bad = []
def runs(st): return "\n".join(str(s.get("run", "")) for s in st)
g = j.get("wui-generate")
if not g: print("no wui-generate job"); sys.exit(0)
gs = g["steps"]
gen = [i for i, s in enumerate(gs) if "pnpm run generate" in str(s.get("run", ""))]
up = [i for i, s in enumerate(gs) if str(s.get("uses", "")).startswith("actions/upload-artifact@")
      and (s.get("with") or {}).get("name") == "wui-mock-bundle"]
bud = [i for i, s in enumerate(gs) if "perf-budget.py bundle" in str(s.get("run", ""))]
if len(gen) != 1: bad.append("wui-generate does not generate exactly once")
if len(up) != 1: bad.append("wui-generate does not upload wui-mock-bundle")
elif (gs[up[0]].get("with") or {}).get("path") != "csi-spl-wui/.output/public": bad.append("upload path is not csi-spl-wui/.output/public")
if gen and up and up[0] < gen[0]: bad.append("upload before generate")
if len(bud) != 1: bad.append("bundle budget not run once in wui-generate")
elif up and bud[0] < up[0]: bad.append("bundle budget runs before the upload")
if up and str(g.get("outputs", {}).get("bundle", "")).replace(" ", "") != "${{steps.%s.outcome}}" % gs[up[0]].get("id"):
    bad.append("wui-generate outputs.bundle is not the upload step's outcome")
e = j["wui-e2e"]; es = e["steps"]
needs = e.get("needs") or []; needs = [needs] if isinstance(needs, str) else needs
cond = str(e.get("if", ""))
if "wui-generate" not in needs: bad.append("wui-e2e does not need wui-generate")
if "needs.wui-generate.outputs.bundle == 'success'" not in cond: bad.append("wui-e2e if: lacks the bundle output gate")
if "needs.wui-generate.result" in cond: bad.append("wui-e2e gated on the whole generate job (a budget miss would skip the e2e)")
if "pnpm run generate" in runs(es): bad.append("wui-e2e still runs nuxt generate")
dl = [i for i, s in enumerate(es) if str(s.get("uses", "")).startswith("actions/download-artifact@")
      and (s.get("with") or {}).get("name") == "wui-mock-bundle"
      and (s.get("with") or {}).get("path") == "csi-spl-wui/.output/public"]
ee = [i for i, s in enumerate(es) if "pnpm run test:e2e" in str(s.get("run", ""))]
if len(dl) != 1: bad.append("wui-e2e does not download wui-mock-bundle into csi-spl-wui/.output/public")
if not ee: bad.append("wui-e2e has no test:e2e step")
elif dl and dl[0] > ee[0]: bad.append("download after the e2e step")
if "wui-generate" not in (j["gate-health"].get("needs") or []): bad.append("gate-health does not wait on wui-generate")
print("\n".join(bad))
PY
}

f="$W/10_ci-quality.yml"
python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") is not valid yaml"
p=$(wf10_problems "$f")
[[ -z "$p" ]] && pass "10: nuxt generate runs once (wui-generate); the 3 shards download the bundle; budget after the upload" \
  || fail "10: $(tr '\n' '|' <<<"$p")"

# --- controls ------------------------------------------------------------------
python3 - "$f" "$T/c1.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); st = wf["jobs"]["wui-e2e"]["steps"]
st.insert(1, {"name": "nuxt generate (mock tenant)", "run": "pnpm run generate"})
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
[[ -n "$(wf10_problems "$T/c1.yml")" ]] && pass "CONTROL: a shard that generates again is reported" \
  || fail "CONTROL: a shard generating its own bundle passed"

python3 - "$f" "$T/c2.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(s.replace("needs.wui-generate.outputs.bundle == 'success'", "needs.wui-generate.result == 'success'", 1))
PY
[[ -n "$(wf10_problems "$T/c2.yml")" ]] && pass "CONTROL: shards gated on the generate job's success are reported" \
  || fail "CONTROL: shards gated on the whole generate job passed"

python3 - "$f" "$T/c3.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); st = wf["jobs"]["wui-generate"]["steps"]
b = next(i for i, s in enumerate(st) if "perf-budget.py bundle" in str(s.get("run", "")))
bud = st.pop(b); u = next(i for i, s in enumerate(st) if s.get("id") == "upload"); st.insert(u, bud)
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
[[ -n "$(wf10_problems "$T/c3.yml")" ]] && pass "CONTROL: a budget moved before the upload is reported" \
  || fail "CONTROL: a budget before the upload passed"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
