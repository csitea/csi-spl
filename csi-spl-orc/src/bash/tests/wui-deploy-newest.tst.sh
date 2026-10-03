#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: wui-deploy-newest.sh dispatches workflow 30 at trunk head when a
#          pending deploy was dropped, and the workflow job that calls it
#          sits outside the deploy concurrency group so a cancelled deploy
#          still reaches it.
#
#   1. this run is the head and the deploy succeeded -> skip, no dispatch
#   2. this run is the head and the deploy was cancelled, nothing in flight
#      -> one dispatch of 30 at master, environment=all
#   3. a newer run is already in flight -> skip
#   4. the head's own deploy failed -> skip (broken, not starved)
#   5. an older run shipped, and the head has a WUI input -> dispatch
#   6. the head moved, but not on a WUI input, and this deploy shipped -> skip
#   7. the head's latest finished run failed -> skip
#   8. gh cannot list runs -> skip, exit 0 (a catch-up must not redden a deploy)
#   9. bad input -> exit 2
#   10. workflow 30's newest job is if: always(), needs deploy, actions: write,
#       calls this script, and has no concurrency group of its own; the deploy
#       job stays cancel-in-progress false
#   CONTROL: a workflow with no newest job fails check 10
#   MUTATION: drop always() from the if, check 10 catches it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
S="$PROJ_ROOT/src/bash/scripts/wui-deploy-newest.sh"
WF="${WF:-$PROJ_ROOT/../.github/workflows/30_wui-build-deploy.yml}"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

[[ -x "$S" ]] && pass "wui-deploy-newest.sh is executable" || fail "wui-deploy-newest.sh is missing or not executable"

# --- synthetic repo: v1 is a WUI commit, docs moves only README, v2 is WUI --
GIT="$T/repo"
mkdir -p "$GIT/csi-spl-wui"
git -C "$GIT" init -q -b master
git -C "$GIT" config user.email t@example.com
git -C "$GIT" config user.name "FirstName LastName"
commit() {
  local rel="$1" body="$2"
  mkdir -p "$GIT/$(dirname "$rel")"
  printf '%s\n' "$body" >"$GIT/$rel"
  git -C "$GIT" add -- "$rel"
  git -C "$GIT" commit -qm "$body"
  git -C "$GIT" rev-parse HEAD
}
V1=$(commit csi-spl-wui/a.txt "wui v1")
DOCS=$(commit README.md "docs only")
V2=$(commit csi-spl-wui/a.txt "wui v2")

mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == run && "$2" == list ]]; then
  echo list >>"$GH_LOG"
  cat "$GH_LIST"
  exit "${GH_LIST_RC:-0}"
fi
if [[ "$1" == workflow && "$2" == run ]]; then
  printf '%s\n' "$*" >>"$GH_LOG"
  exit "${GH_RUN_RC:-0}"
fi
echo "unexpected: $*" >>"$GH_LOG"
exit 9
SH
chmod +x "$T/bin/gh"

# run <sha> <tip> <result> <list-json> [list-rc]
run() {
  : >"$T/gh.log"
  printf '%s' "$4" >"$T/list.json"
  OUT=$(PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GH_LIST="$T/list.json" GH_LIST_RC="${5:-0}" \
    SHA="$1" TIP="$2" RUN_ID=100 DEPLOY_RESULT="$3" REPO=org/repo APP_PATH="$GIT" \
    bash "$S" 2>"$T/err")
  rc=$?
}

empty='[]'
other_inflight='[{"databaseId":200,"status":"in_progress","conclusion":"","headSha":"'"$V2"'"}]'
tip_failed='[{"databaseId":200,"status":"completed","conclusion":"failure","headSha":"'"$V2"'"}]'
tip_ok='[{"databaseId":200,"status":"completed","conclusion":"success","headSha":"'"$V2"'"}]'
want_dispatch='workflow run 30_wui-build-deploy.yml --repo org/repo --ref master -f environment=all'

run "$V2" "$V2" success "$empty"
[[ $rc -eq 0 && "$OUT" == "skip this-run-success" && ! -s "$T/gh.log" ]] \
  && pass "1. head shipped: skip, gh not called" \
  || fail "1. rc=$rc out='$OUT' gh=$(tr '\n' '|' <"$T/gh.log")"

run "$V2" "$V2" cancelled "$empty"
[[ $rc -eq 0 && "$OUT" == "dispatch" && $(grep -c . <"$T/gh.log") -eq 2 ]] \
  && grep -qx "$want_dispatch" "$T/gh.log" \
  && pass "2. head deploy cancelled, nothing in flight: one dispatch at master" \
  || fail "2. rc=$rc out='$OUT' gh=$(tr '\n' '|' <"$T/gh.log") err=$(tr '\n' '|' <"$T/err")"

run "$V1" "$V2" cancelled "$other_inflight"
[[ $rc -eq 0 && "$OUT" == "skip inflight" ]] \
  && pass "3. a newer run is in flight: skip" \
  || fail "3. rc=$rc out='$OUT'"

run "$V2" "$V2" failure "$empty"
[[ $rc -eq 0 && "$OUT" == "skip broken" && ! -s "$T/gh.log" ]] \
  && pass "4. the head's own deploy failed: skip, no dispatch" \
  || fail "4. rc=$rc out='$OUT' gh=$(tr '\n' '|' <"$T/gh.log")"

run "$V1" "$V2" success "$empty"
[[ $rc -eq 0 && "$OUT" == "dispatch" ]] && grep -qx "$want_dispatch" "$T/gh.log" \
  && pass "5. older run shipped, head has a WUI input, nothing in flight: dispatch" \
  || fail "5. rc=$rc out='$OUT' gh=$(tr '\n' '|' <"$T/gh.log")"

run "$V1" "$DOCS" success "$empty"
[[ $rc -eq 0 && "$OUT" == "skip no-wui-input" && $(grep -c . <"$T/gh.log") -eq 1 ]] \
  && pass "6. head moved on docs only, this deploy shipped: skip" \
  || fail "6. rc=$rc out='$OUT' gh=$(tr '\n' '|' <"$T/gh.log")"

run "$V1" "$V2" cancelled "$tip_failed"
[[ $rc -eq 0 && "$OUT" == "skip broken" ]] \
  && pass "7. the head's latest finished run failed: skip" \
  || fail "7. rc=$rc out='$OUT'"

run "$V1" "$V2" success "$tip_ok"
[[ $rc -eq 0 && "$OUT" == "skip already-succeeded" ]] \
  && pass "7b. a successful run already exists at the head: skip" \
  || fail "7b. rc=$rc out='$OUT'"

run "$V2" "$V2" cancelled "$empty" 1
[[ $rc -eq 0 && "$OUT" == "skip gh-list" ]] \
  && pass "8. gh run list fails: skip, exit 0" \
  || fail "8. rc=$rc out='$OUT'"

run "$V2" "$V2" bogus "$empty"
[[ $rc -eq 2 ]] && pass "9. a bad DEPLOY_RESULT exits 2" || fail "9. rc=$rc out='$OUT'"

# --- 10. the workflow job is outside the deploy lock ------------------------
wiring() {
  python3 - "$1" <<'PY'
import sys, yaml
try:
    wf = yaml.safe_load(open(sys.argv[1]))
except Exception as e:
    print("yaml: %s" % e); raise SystemExit
jobs = wf.get("jobs") or {}
job = jobs.get("newest")
if not isinstance(job, dict):
    print("no newest job"); raise SystemExit
bad = []
iff = str(job.get("if", ""))
if "always()" not in iff:
    bad.append("if lacks always()")
if "push" not in iff:
    bad.append("if is not limited to a push")
needs = job.get("needs") or []
if isinstance(needs, str):
    needs = [needs]
if "deploy" not in needs:
    bad.append("does not need deploy")
if job.get("concurrency"):
    bad.append("newest has its own concurrency group")
if (job.get("permissions") or {}).get("actions") != "write":
    bad.append("actions is not write")
runs = " ".join(str(s.get("run", "")) for s in (job.get("steps") or []))
if "wui-deploy-newest.sh" not in runs:
    bad.append("does not call wui-deploy-newest.sh")
dep = jobs.get("deploy") or {}
c = dep.get("concurrency") or {}
if c.get("cancel-in-progress") is not False:
    bad.append("deploy concurrency is not cancel-in-progress false")
print("\n".join(bad))
PY
}

w=$(wiring "$WF")
[[ -z "$w" ]] && pass "10. newest runs even after a cancelled deploy, outside the deploy lock" \
  || fail "10. $(tr '\n' '|' <<<"$w")"

python3 - "$WF" "$T/none.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
wf["jobs"].pop("newest", None)
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
w=$(wiring "$T/none.yml")
[[ "$w" == "no newest job" ]] && pass "CONTROL: a workflow with no newest job fails the check" \
  || fail "CONTROL: $(tr '\n' '|' <<<"$w")"

python3 - "$WF" "$T/mut.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace("always() && ", "", 1)
open(sys.argv[2], "w").write(s)
PY
w=$(wiring "$T/mut.yml")
[[ "$w" == *"always()"* ]] && pass "MUTATION: dropping always() is caught" \
  || fail "MUTATION: $(tr '\n' '|' <<<"$w")"

echo "--- $fails failure(s)"
[[ "$fails" -eq 0 ]]
