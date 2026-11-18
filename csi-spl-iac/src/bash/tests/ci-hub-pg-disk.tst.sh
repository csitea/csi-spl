#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: perf round 18 row 02 - the hub-pg job of 10_ci-quality.yml frees
# disk on a hosted runner only when the runner is short (a hosted runner
# starts with ~88 GB free, the step cost ~100 s a job).
# What must hold:
#   a. hub-pg's free-up step carries a condition on a measured free-space
#      output (steps.<id>.outputs.short of a disk guard step in report mode,
#      CI_DISK_REPORT=1, run before it), not only runner.environment; the
#      report's need adds the cache's unpacked size (CI_GO_CACHE_SAVE_MAX_MB)
#   b. the hard guard (no report mode, no `if:`) still runs after the free-up
#      and before the cache restore (SPL-4790)
#   c. CONTROL: a copy with today's unconditional free-up, and one whose hard
#      guard is put in report mode, are each reported
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W="$APP_ROOT/.github/workflows"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# hub_pg_disk_problems <wf file> -> one line per broken rule (empty = ok)
hub_pg_disk_problems() {
  python3 - "$1" <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); st = wf["jobs"]["hub-pg"]["steps"]; bad = []
def idx(pred): return [i for i, s in enumerate(st) if pred(s)]
def run(s): return str(s.get("run", ""))
def env(s): return s.get("env") or {}
def guard(s): return "ci-disk-guard.sh" in run(s)
def report(s): return guard(s) and str(env(s).get("CI_DISK_REPORT", "")) == "1"
free = idx(lambda s: "sudo rm -rf" in run(s) and "/usr/share/dotnet" in run(s))
rest = idx(lambda s: str(s.get("uses", "")).startswith("actions/cache/restore@"))
hard = idx(lambda s: guard(s) and not report(s))
if len(free) != 1:
    bad.append("hub-pg has no free-up step"); print("\n".join(bad)); sys.exit(0)
fi = free[0]; cond = str(st[fi].get("if", ""))
if "runner.environment == 'github-hosted'" not in cond:
    bad.append("the free-up is no longer limited to a hosted runner")
m = re.search(r"steps\.([A-Za-z0-9_-]+)\.outputs\.short == 'true'", cond)
rep = [i for i, s in enumerate(st) if m and s.get("id") == m.group(1)]
if not m:
    bad.append("the free-up runs on every hosted runner: no condition on a measured free-space output")
elif not rep or not report(st[rep[0]]):
    bad.append("the free-up's condition names no disk guard step in report mode")
elif rep[0] > fi:
    bad.append("the report step runs after the free-up")
elif "CI_GO_CACHE_SAVE_MAX_MB" not in run(st[rep[0]]) + str(env(st[rep[0]])):
    bad.append("the report's need does not add the cache's unpacked size (CI_GO_CACHE_SAVE_MAX_MB)")
if not rest: bad.append("hub-pg has no cache restore")
ok_hard = [i for i in hard if i > fi and rest and i < rest[0] and not st[i].get("if")]
if not ok_hard: bad.append("no hard disk guard (no report mode, no if:) between the free-up and the cache restore")
print("\n".join(bad))
PY
}

f="$W/10_ci-quality.yml"
python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") is not valid yaml"
p=$(hub_pg_disk_problems "$f")
[[ -z "$p" ]] && pass "10: hub-pg frees disk only when the report step finds the runner short (need + cache); the hard guard still runs before the restore" \
  || fail "10: $(tr '\n' '|' <<<"$p")"

# --- controls ------------------------------------------------------------------
python3 - "$f" "$T/c1.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for s in wf["jobs"]["hub-pg"]["steps"]:
    if "/usr/share/dotnet" in str(s.get("run", "")):
        s["if"] = "${{ runner.environment == 'github-hosted' }}"
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
[[ -n "$(hub_pg_disk_problems "$T/c1.yml")" ]] && pass "CONTROL: today's unconditional free-up (hosted only) is reported" \
  || fail "CONTROL: an unconditional free-up passed"

python3 - "$f" "$T/c2.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for s in wf["jobs"]["hub-pg"]["steps"]:
    if "ci-disk-guard.sh" in str(s.get("run", "")):
        s["env"] = dict(s.get("env") or {}, CI_DISK_REPORT="1")
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
[[ -n "$(hub_pg_disk_problems "$T/c2.yml")" ]] && pass "CONTROL: a hard guard put in report mode is reported" \
  || fail "CONTROL: a guard in report mode before the restore passed as the hard guard"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
