#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: perf round 18 row 01 - the hub-suite job of 10_ci-quality.yml builds
# warm: it restores its own Go build cache before run-all-tests.sh.
# What must hold:
#   a. hub-suite has an actions/cache/restore step on GOCACHE whose key starts
#      go-hub-suite-, and it runs before run-all-tests.sh
#   b. its actions/cache/save step runs only on an exact miss and never on a
#      pull request, after the trim (find ... -delete since the mark) and the
#      size cap (ci-cache-save-cap.sh), and saves the restore's primary key
#   c. CONTROL: hub-pg's restore key prefix is still go-race-pg-v2- (the two
#      jobs build different sets, so a shared entry would trim the other's)
#   d. CONTROL: a copy with the restore moved after run-all-tests.sh, and one
#      whose save runs on a pull request, are each reported
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W="$APP_ROOT/.github/workflows"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# hub_suite_problems <wf file> -> one line per broken rule (empty = ok)
hub_suite_problems() {
  python3 - "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); j = wf["jobs"]; bad = []
st = j["hub-suite"]["steps"]
def idx(pred): return [i for i, s in enumerate(st) if pred(s)]
def uses(s, p): return str(s.get("uses", "")).startswith(p)
def w(s): return s.get("with") or {}
def run(s): return str(s.get("run", ""))
pg = [s for s in j["hub-pg"]["steps"] if uses(s, "actions/cache/restore@")]
if not pg or not str(w(pg[0]).get("key", "")).startswith("go-race-pg-v2-"):
    bad.append("hub-pg's restore key prefix is no longer go-race-pg-v2-")
tests = idx(lambda s: "run-all-tests.sh" in run(s))
rest = idx(lambda s: uses(s, "actions/cache/restore@") and "gocache" in str(w(s).get("path", ""))
           and str(w(s).get("key", "")).startswith("go-hub-suite-"))
if not tests: bad.append("hub-suite has no run-all-tests.sh step")
if len(rest) != 1:
    bad.append("hub-suite restores no Go build cache"); print("\n".join(bad)); sys.exit(0)
r = st[rest[0]]; rid = r.get("id", "")
if tests and rest[0] > tests[0]: bad.append("hub-suite restores its Go build cache after run-all-tests.sh")
if not rid: bad.append("the hub-suite restore step has no id")
setup = idx(lambda s: uses(s, "actions/setup-go@"))
if not setup or st[setup[0]].get("id") != "setup-go": bad.append("hub-suite's Set up Go has no id setup-go")
if "steps.setup-go.outputs.go-version" not in str(w(r).get("key", "")): bad.append("the restore key does not carry the go version")
if not str(w(r).get("restore-keys", "")).strip(): bad.append("the restore has no restore-keys")
miss = "steps.%s.outputs.cache-hit != 'true'" % rid
nopr = "github.event_name != 'pull_request'"
mark = idx(lambda s: "gocache.mark" in run(s) and "touch" in run(s))
trim = idx(lambda s: "-delete" in run(s) and "gocache.mark" in run(s))
cap = idx(lambda s: "ci-cache-save-cap.sh" in run(s))
save = idx(lambda s: uses(s, "actions/cache/save@") and "gocache" in str(w(s).get("path", "")))
if len(save) != 1:
    bad.append("hub-suite saves no Go build cache"); print("\n".join(bad)); sys.exit(0)
sv = save[0]; c = str(st[sv].get("if", ""))
if miss not in c: bad.append("the save does not run on an exact miss only")
if nopr not in c: bad.append("the save may run on a pull request")
if str(w(st[sv]).get("key", "")).replace(" ", "") != "${{steps.%s.outputs.cache-primary-key}}" % rid:
    bad.append("the save does not write the restore's primary key")
if not mark or mark[0] < rest[0]: bad.append("no mark step after the restore")
if not trim or trim[0] > sv: bad.append("no trim step before the save")
if not cap or cap[0] > sv: bad.append("no size cap before the save")
if tests and sv < tests[0]: bad.append("the save runs before run-all-tests.sh")
for i in trim[:1] + cap[:1]:
    ci = str(st[i].get("if", ""))
    if miss not in ci or nopr not in ci:
        bad.append("step %r is not limited to an exact miss off a pull request" % st[i].get("name"))
print("\n".join(bad))
PY
}

f="$W/10_ci-quality.yml"
python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") is not valid yaml"
p=$(hub_suite_problems "$f")
[[ -z "$p" ]] && pass "10: hub-suite restores its own Go build cache (go-hub-suite-) before run-all-tests.sh; saves on an exact miss, never on a PR, after the trim and the cap; hub-pg keeps go-race-pg-v2-" \
  || fail "10: $(tr '\n' '|' <<<"$p")"

# --- controls ------------------------------------------------------------------
python3 - "$f" "$T/c1.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); st = wf["jobs"]["hub-suite"]["steps"]
r = next((i for i, s in enumerate(st) if str(s.get("uses", "")).startswith("actions/cache/restore@")), None)
if r is not None:
    rs = st.pop(r); t = next(i for i, s in enumerate(st) if "run-all-tests.sh" in str(s.get("run", ""))); st.insert(t + 1, rs)
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
[[ -n "$(hub_suite_problems "$T/c1.yml")" ]] && pass "CONTROL: a restore moved after run-all-tests.sh is reported" \
  || fail "CONTROL: a restore after run-all-tests.sh passed"

python3 - "$f" "$T/c2.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); st = wf["jobs"]["hub-suite"]["steps"]
for s in st:
    if str(s.get("uses", "")).startswith("actions/cache/save@"):
        s["if"] = str(s.get("if", "")).replace("github.event_name != 'pull_request'", "true")
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
[[ -n "$(hub_suite_problems "$T/c2.yml")" ]] && pass "CONTROL: a save that runs on a pull request is reported" \
  || fail "CONTROL: a save on a pull request passed"

python3 - "$f" "$T/c3.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for s in wf["jobs"]["hub-pg"]["steps"]:
    k = (s.get("with") or {}).get("key", "")
    if str(s.get("uses", "")).startswith("actions/cache/restore@"):
        s["with"]["key"] = str(k).replace("go-race-pg-v2-", "go-hub-suite-v1-", 1)
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
[[ -n "$(hub_suite_problems "$T/c3.yml")" ]] && pass "CONTROL: hub-pg on the hub-suite key prefix is reported" \
  || fail "CONTROL: hub-pg sharing the hub-suite key prefix passed"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
