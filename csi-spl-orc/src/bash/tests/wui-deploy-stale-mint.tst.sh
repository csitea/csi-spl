#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: workflow 30 (WUI deploy) stands down on a stale release mint, as
# workflow 20 does since 5d6efd00 (CLE-77950). GitHub refuses the Actions token
# any ref at a commit whose .github/workflows differs from trunk head's, and
# the mint then returns rc 3 + stale=true (release-version test 13). This test
# runs the mint step's OWN run: script, cut from the workflow file, against a
# stub ./csi-spl-orc/run and a stub gh:
#   1. stale on a push, first env -> exit 0, ONE dispatch of 30 at master, all
#   2. stale on a push, the other env -> exit 0, no dispatch
#   3. stale on an operator dispatch -> exit 1 naming the cause, no dispatch
#   4. a minted version -> exit 0, no dispatch; a real mint error -> its rc
#   5. every step after the mint is skipped on stale (its if: reads
#      steps.ver.outputs.stale), and the deploy job may dispatch (actions: write)
#   CONTROL: the pre-fix mint step fails case 1 (the deploy went red)
#   MUTATION CONTROL: drop the guard from one later step -> check 5 sees it
# (CLE-77958)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
WF="${WF:-$PROJ_ROOT/../.github/workflows/30_wui-build-deploy.yml}"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# the mint step's run: script (python yaml, as on every runner image)
mint_script() {
  python3 - "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for s in wf["jobs"]["deploy"]["steps"]:
    if s.get("id") == "ver":
        print(s["run"]); break
PY
}

# stub ./csi-spl-orc/run: MINT=ok|stale|error decides what the mint did
mkdir -p "$T/ws/csi-spl-orc" "$T/bin"
cat >"$T/ws/csi-spl-orc/run" <<'SH'
#!/usr/bin/env bash
case "$MINT" in
  ok)    echo "version=1.2.3" >>"$GITHUB_OUTPUT"; exit 0 ;;
  stale) echo "stale=true" >>"$GITHUB_OUTPUT"; exit 3 ;;
  *)     exit 1 ;;
esac
SH
cat >"$T/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
SH
chmod +x "$T/ws/csi-spl-orc/run" "$T/bin/gh"

# run <script> <MINT> <EVENT> <ENV> <FIRST_ENV> -> rc; gh calls in $T/gh.log
run() {
  : >"$T/out"; : >"$T/gh.log"
  (cd "$T/ws" && PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GITHUB_OUTPUT="$T/out" \
    GITHUB_SHA=0123456789abcdef GITHUB_REPOSITORY=org/repo \
    MINT="$2" EVENT="$3" ENV="$4" FIRST_ENV="$5" \
    bash --noprofile --norc -eo pipefail "$1" >"$T/log" 2>&1)
}

mint_script "$WF" >"$T/mint.sh"
[[ -s "$T/mint.sh" ]] && pass "the mint step (id: ver) is in $(basename "$WF")" || fail "no mint step in $WF"

# --- 1..4 -------------------------------------------------------------------
rc=0; run "$T/mint.sh" stale push dev dev || rc=$?
if [[ $rc -eq 0 && $(wc -l <"$T/gh.log") -eq 1 ]] \
   && grep -qx 'workflow run 30_wui-build-deploy.yml --repo org/repo --ref master -f environment=all' "$T/gh.log"; then
  pass "stale on a push, first env: stands down (exit 0), dispatches 30 at master once (environment=all)"
else fail "stale/push/first: rc=$rc gh=$(tr '\n' '|' <"$T/gh.log") log=$(tr '\n' '|' <"$T/log" | cut -c1-200)"; fi

rc=0; run "$T/mint.sh" stale push prd dev || rc=$?
[[ $rc -eq 0 && ! -s "$T/gh.log" ]] && pass "stale on a push, the other env: stands down, no second dispatch" \
  || fail "stale/push/other: rc=$rc gh=$(tr '\n' '|' <"$T/gh.log")"

rc=0; run "$T/mint.sh" stale workflow_dispatch dev dev || rc=$?
if [[ $rc -ne 0 && ! -s "$T/gh.log" ]] && grep -q "differs from trunk head's" "$T/log"; then
  pass "stale on an operator dispatch: fails naming the cause, never re-dispatches"
else fail "stale/dispatch: rc=$rc gh=$(tr '\n' '|' <"$T/gh.log") log=$(tr '\n' '|' <"$T/log" | cut -c1-200)"; fi

rc=0; run "$T/mint.sh" ok push dev dev || rc=$?
[[ $rc -eq 0 && ! -s "$T/gh.log" ]] && grep -qx 'version=1.2.3' "$T/out" \
  && pass "a minted version passes through, no dispatch" || fail "ok mint: rc=$rc"

rc=0; run "$T/mint.sh" error push dev dev || rc=$?
[[ $rc -ne 0 && ! -s "$T/gh.log" ]] && pass "a real mint error still fails the job (rc $rc)" || fail "error mint: rc=$rc"

# --- 5. every later step is guarded; the job may dispatch -------------------
unguarded() {
  python3 - "$1" <<'PY'
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["deploy"]
steps = job["steps"]; i = [s.get("id") for s in steps].index("ver")
bad = [s.get("name") or s.get("uses") for s in steps[i + 1:]
       if "steps.ver.outputs.stale != 'true'" not in str(s.get("if", ""))]
if job.get("permissions", {}).get("actions") != "write":
    bad.append("deploy.permissions.actions != write")
print("\n".join(bad))
PY
}
u=$(unguarded "$WF")
[[ -z "$u" ]] && pass "every step after the mint skips on stale; deploy has actions: write" \
  || fail "not stale-guarded: $(tr '\n' '|' <<<"$u")"

# --- CONTROL: the pre-fix mint step (before CLE-77958) ----------------------
cat >"$T/prefix.sh" <<'SH'
set -euo pipefail
DRY_RUN=0 RELEASE_SHA="$GITHUB_SHA" ./csi-spl-orc/run -a do_release_version
grep -q '^version=[0-9]\.[0-9]\.[0-9]$' "$GITHUB_OUTPUT" || { echo "::error::no release version minted"; exit 1; }
SH
rc=0; run "$T/prefix.sh" stale push dev dev || rc=$?
[[ $rc -ne 0 && ! -s "$T/gh.log" ]] && pass "CONTROL: the pre-fix mint step fails a stale push (rc $rc) and dispatches nothing" \
  || fail "CONTROL: the pre-fix step passed a stale mint (rc=$rc) - this test cannot tell the fix from its absence"

# --- MUTATION CONTROL: one later step loses its guard -----------------------
python3 - "$WF" "$T/mut.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
k = "steps.ver.outputs.stale != 'true' && "
i = s.rindex(k)   # the last guarded step
open(sys.argv[2], "w").write(s[:i] + s[i + len(k):])
PY
u=$(unguarded "$T/mut.yml")
[[ -n "$u" ]] && pass "MUTATION CONTROL: an unguarded later step is caught ($(tr '\n' '|' <<<"$u"))" \
  || fail "MUTATION CONTROL: check 5 missed a step that lost its stale guard"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
